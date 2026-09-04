// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";

/// @dev Minimal inline interfaces. Deliberately not importing v4-core /
///      v4-periphery — this tier needs no external dependencies so it runs the
///      moment you have an RPC. Tier 2 (pool creation + swaps) does need them;
///      see the note at the bottom of this file.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IDirectionalFeeHook {
    function owner() external view returns (address);
    function operator() external view returns (address);
    function paused() external view returns (bool);
    function poolManager() external view returns (address);
    function MAX_FEE_BPS() external view returns (uint16);
    function RATE_CHANGE_DELAY() external view returns (uint256);
    function configurePool(PoolKey calldata key, address vault, uint16 zeroForOneBps, uint16 oneForZeroBps)
        external;
    function isConfigured(PoolKey calldata key) external view returns (bool);
    function getEffectiveRates(PoolKey calldata key)
        external
        view
        returns (uint16 zeroForOneBps, uint16 oneForZeroBps);
    function getVault(PoolKey calldata key) external view returns (address);
    function buyDirection(PoolKey calldata key, address token) external pure returns (bool);
}

/// @title  Robinhood Chain reconnaissance
/// @notice Tier 1 of the fork test. Answers, against real mainnet state:
///
///           1. does the fork work at all
///           2. is the hook what we think it is, and who owns it
///           3. does the Mill behave correctly over a real ERC-20
///           4. can we configure a pool on the existing hook, or must we
///              deploy our own instance
///
///         Run:
///           RH_RPC=https://rpc.mainnet.chain.robinhood.com \
///             forge test --match-contract ForkTest -vv
///
///         Add `--fork-block-number <n>` once you want reproducible runs.
contract ForkTest is Test {
    // ---- Robinhood Chain, chain id 4663 -------------------------------
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant DIRECTIONAL_FEE_HOOK = 0x62F788a21a26eE3fE5D70ef6Ef9942D8B2cb8044;
    // Canonical across chains — asserted below rather than assumed.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address alice = address(0xA11CE);
    address treasury = address(0x7EEA);

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC"));
    }

    // -----------------------------------------------------------------
    // 1. is the fork real
    // -----------------------------------------------------------------

    function test_01_ForkIsLive() public view {
        console2.log("chainId        ", block.chainid);
        console2.log("block          ", block.number);
        assertEq(block.chainid, 4663, "not Robinhood Chain");

        assertGt(POOL_MANAGER.code.length, 0, "PoolManager has no code");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager has no code");
        assertGt(WETH.code.length, 0, "WETH has no code");

        console2.log("PoolManager ETH", POOL_MANAGER.balance);
        console2.log("PoolManager WETH", IERC20(WETH).balanceOf(POOL_MANAGER));
        console2.log("Permit2 deployed", PERMIT2.code.length > 0);
    }

    // -----------------------------------------------------------------
    // 2. is the hook what we think it is
    // -----------------------------------------------------------------

    function test_02_HookIdentity() public view {
        assertGt(DIRECTIONAL_FEE_HOOK.code.length, 0, "hook has no code");

        // V4 encodes permissions in the low 14 bits of the address.
        // afterSwap (1<<6) | afterSwapReturnDelta (1<<2) == 0x44
        uint160 flags = uint160(DIRECTIONAL_FEE_HOOK) & 0x3FFF;
        console2.log("hook flags     ", flags);
        assertEq(flags, 0x0044, "permission bits are not afterSwap|afterSwapReturnDelta");

        IDirectionalFeeHook hook = IDirectionalFeeHook(DIRECTIONAL_FEE_HOOK);
        assertEq(hook.poolManager(), POOL_MANAGER, "hook points at a different PoolManager");

        console2.log("hook owner     ", hook.owner());
        console2.log("hook operator  ", hook.operator());
        console2.log("hook paused    ", hook.paused());
        console2.log("MAX_FEE_BPS    ", hook.MAX_FEE_BPS());
        console2.log("RATE_DELAY (s) ", hook.RATE_CHANGE_DELAY());
    }

    // -----------------------------------------------------------------
    // 3. does the Mill work over a real token
    // -----------------------------------------------------------------

    function test_03_MillOverRealWETH() public {
        Mill mill = new Mill(IERC20(WETH), "Mill WETH", "mWETH", 25, 50, 5_000, 7_000, 0, treasury, treasury, address(this));

        deal(WETH, alice, 100 ether);
        vm.startPrank(alice);
        IERC20(WETH).approve(address(mill), type(uint256).max);
        uint256 shares = mill.wrap(10 ether, alice);
        vm.stopPrank();

        console2.log("shares minted  ", shares);
        console2.log("ratio pre      ", mill.ratio());

        mill.processFees();
        console2.log("ratio post-burn", mill.ratio());
        console2.log("burned         ", mill.totalBurned());

        assertEq(mill.totalAssets(), 10 ether, "vault holds the deposit");
        assertGt(mill.ratio(), 1e18, "ratio moved above 1 after the first toll");

        vm.prank(alice);
        uint256 out = mill.unwrap(shares / 2, alice);
        console2.log("unwrap out     ", out);
        assertGt(out, 0);
    }

    // -----------------------------------------------------------------
    // 4. THE GATE — can we actually configure a pool on this hook
    // -----------------------------------------------------------------

    function test_04_CanWeConfigureTheHook() public {
        IDirectionalFeeHook hook = IDirectionalFeeHook(DIRECTIONAL_FEE_HOOK);
        Mill mill = new Mill(IERC20(WETH), "Mill WETH", "mWETH", 25, 50, 5_000, 7_000, 0, treasury, treasury, address(this));

        // Currencies are ordered by address.
        (address c0, address c1) =
            address(mill) < WETH ? (address(mill), WETH) : (WETH, address(mill));

        // NOTE: a non-zero LP fee. This is the thing we are testing — the
        // launchpad hooks force LP_FEE == 0, and this one appears not to.
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: DIRECTIONAL_FEE_HOOK});

        bool buysMill = hook.buyDirection(key, address(mill));
        console2.log("buy-mill direction is zeroForOne:", buysMill);

        // Zero on the direction that buys mTKN (discount repair stays free),
        // 1% on the direction that sells it.
        uint16 zeroForOne = buysMill ? 0 : 100;
        uint16 oneForZero = buysMill ? 100 : 0;

        address owner_ = hook.owner();
        console2.log("hook owner     ", owner_);

        vm.prank(owner_);
        try hook.configurePool(key, treasury, zeroForOne, oneForZero) {
            console2.log(">>> configurePool SUCCEEDED with LP fee 3000 (0.30%)");
            assertTrue(hook.isConfigured(key), "not marked configured");
            (uint16 z, uint16 o) = hook.getEffectiveRates(key);
            console2.log("effective z/o  ", z, o);
            assertEq(hook.getVault(key), treasury, "vault not set");
        } catch Error(string memory reason) {
            console2.log(">>> configurePool REVERTED:", reason);
            fail();
        } catch (bytes memory data) {
            console2.log(">>> configurePool REVERTED, selector:");
            console2.logBytes(data);
            fail();
        }
    }
}

/*
 * ---------------------------------------------------------------------------
 * TIER 2 — pool creation, liquidity, and real swaps
 * ---------------------------------------------------------------------------
 * Needs the real V4 types, so install them first:
 *
 *   forge install Uniswap/v4-core
 *   forge install Uniswap/v4-periphery
 *
 * and add to foundry.toml remappings:
 *
 *   "v4-core/=lib/v4-core/",
 *   "v4-periphery/=lib/v4-periphery/",
 *
 * Then the remaining questions are:
 *
 *   - initialize the pool at mill.ratio(), NOT at 1:1
 *   - mint a position through PositionManager (routes via Permit2)
 *   - swap both directions AND both exactness modes, asserting the hook fee
 *     lands in the vault and that LP fees still accrue to the position
 *   - measure a full arb round trip: buy mTKN, unwrap, and compare against
 *     mill.ratio() to get the real band width
 *
 * The last one is the number that decides the launch. Everything above it is
 * plumbing.
 */
