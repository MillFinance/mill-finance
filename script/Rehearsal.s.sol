// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {Mill} from "../src/Mill.sol";
import {MillPoolMath} from "../src/MillPoolMath.sol";

/// ---------------------------------------------------------------------------
/// STEP 7, REHEARSED
///
/// The same sequence `ForkTier2Test` proves in simulation, split into scripts
/// you broadcast one at a time so nothing irreversible happens inside a step you
/// have not read the output of.
///
/// Order:
///   1. Recon          — TokenReconTest against the token you bought
///   2. DeployMill     — script/Deploy.s.sol:Deploy (seeds in the same run)
///   3. DeployRouters  — this file, one-off plumbing
///   4. ConfigurePool  — script/DeployHook.s.sol:ConfigurePool   << IRREVERSIBLE
///   5. InitPool       — this file, at ratio()                   << IRREVERSIBLE
///   6. AddLiquidity   — this file
///   7. SwapProbe      — this file, both directions
///   8. Report         — this file, after every step
///
/// Every script reads the signer from the CLI (`--account deployer`), never
/// from an env var, so no key reaches shell history or a broadcast artifact.
///
/// These routers are v4-core's TEST routers. They are correct and they are the
/// right tool for a rehearsal, but they hold no position NFT — so the liquidity
/// they mint cannot be locked or shown in the Uniswap UI. Real protocol-owned
/// liquidity goes through PositionManager instead.
/// ---------------------------------------------------------------------------

abstract contract PoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function _key() internal view returns (PoolKey memory key, bool millIsCurrency0, Mill mill) {
        mill = Mill(vm.envAddress("MILL"));
        address quote = vm.envAddress("QUOTE");
        (address c0, address c1, bool m0) = MillPoolMath.order(address(mill), quote);
        millIsCurrency0 = m0;
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: uint24(vm.envOr("LP_FEE", uint256(3000))),
            tickSpacing: int24(uint24(vm.envOr("TICK_SPACING", uint256(60)))),
            hooks: IHooks(vm.envAddress("HOOK"))
        });
    }

    /// @notice The sqrt price this pool sits at when the milled token is exactly
    ///         at backing.
    /// @dev `ratio()` is denominated in the UNDERLYING. When the pool is quoted
    ///      in anything else - mMILL against wETH - the pool price is the ratio
    ///      times the market price of the underlying, and there is no safe
    ///      default for that second number. Shared between InitPool and Report
    ///      deliberately: a Report that computes its target differently from the
    ///      price the pool was opened at is worse than no Report, because it
    ///      reads as an emergency when nothing is wrong.
    function _backingSqrtPrice(Mill mill, bool m0) internal view returns (uint160 sqrtPriceX96, uint256 quotePer) {
        address quote = vm.envAddress("QUOTE");
        address underlying = address(mill.asset());
        quotePer = vm.envOr("QUOTE_PER_ASSET", uint256(0));

        if (quote == underlying) {
            if (quotePer == 0) quotePer = 1e18;
            require(quotePer == 1e18, "QUOTE is the underlying: QUOTE_PER_ASSET must be 1e18 or unset");
        } else {
            require(
                quotePer > 0,
                "QUOTE is not the underlying. Set QUOTE_PER_ASSET to the market price of one whole underlying in whole quote, 1e18-scaled."
            );
        }

        sqrtPriceX96 = MillPoolMath.sqrtPriceAtRatioWithQuote(
            mill.ratio(),
            mill.DECIMALS_OFFSET(),
            quotePer,
            IERC20Metadata(underlying).decimals(),
            IERC20Metadata(quote).decimals(),
            m0
        );
    }
}

/// @notice One-off. Deploys the two routers the rehearsal swaps and mints through.
///   forge script script/Rehearsal.s.sol:DeployRouters --rpc-url rh --account deployer --sender 0x.. --broadcast
contract DeployRouters is PoolScript {
    function run() external {
        vm.startBroadcast();
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        vm.stopBroadcast();

        console2.log("SWAP_ROUTER=", address(swapRouter));
        console2.log("LP_ROUTER=  ", address(lpRouter));
    }
}

/// @notice Initialises the pool AT BACKING. Irreversible: a pool can only be
///         initialised once, and its opening price is where the first trade happens.
///   HOOK=.. MILL=.. QUOTE=.. forge script script/Rehearsal.s.sol:InitPool --rpc-url rh --account deployer --sender 0x.. --broadcast
contract InitPool is PoolScript {
    function run() external {
        (PoolKey memory key, bool m0, Mill mill) = _key();

        // Settle first. Unprocessed fee shares are still counted in totalSupply,
        // so ratio() reads BELOW true backing until they are burned — and this
        // step is irreversible. Opening the pool low hands the first arber free
        // money out of protocol-owned liquidity. processFees is permissionless.
        vm.broadcast();
        mill.processFees();

        uint256 r = mill.ratio();
        require(r > 0, "ratio is zero; seed the Mill first");

        address quote = vm.envAddress("QUOTE");
        address underlying = address(mill.asset());
        (uint160 sqrtPriceX96, uint256 quotePer) = _backingSqrtPrice(mill, m0);

        console2.log("mill            ", address(mill));
        console2.log("underlying      ", underlying);
        console2.log("quote           ", quote);
        console2.log("ratio (1e18)    ", r);
        console2.log("quote/underlying", quotePer);
        console2.log("millIsCurrency0 ", m0);
        console2.log("sqrtPriceX96    ", sqrtPriceX96);
        if (quote != underlying) {
            console2.log(">>> CHECK THIS: one whole", mill.symbol());
            console2.log("    opens at (1e18-scaled quote)", Math.mulDiv(r, quotePer, 1e18));
        }
        require(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price out of range");

        vm.startBroadcast();
        int24 tick = IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("opened at tick  ", tick);
    }
}

/// @notice Mints full-range liquidity through the test router.
///   HOOK=.. MILL=.. QUOTE=.. LP_ROUTER=.. LIQUIDITY=30000000000000000000000 \
///     forge script script/Rehearsal.s.sol:AddLiquidity --rpc-url rh --account deployer --sender 0x.. --broadcast
contract AddLiquidity is PoolScript {
    function run() external {
        (PoolKey memory key, , Mill mill) = _key();
        PoolModifyLiquidityTest lpRouter = PoolModifyLiquidityTest(vm.envAddress("LP_ROUTER"));
        int256 liquidity = int256(vm.envUint("LIQUIDITY"));
        int24 spacing = key.tickSpacing;

        vm.startBroadcast();
        IERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: (TickMath.MIN_TICK / spacing) * spacing,
                tickUpper: (TickMath.MAX_TICK / spacing) * spacing,
                liquidityDelta: liquidity,
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopBroadcast();

        console2.log("liquidity added ", uint256(liquidity));
        console2.log("mill left       ", mill.balanceOf(msg.sender));
    }
}

/// @notice One swap, either direction, exact input. Prints what the vault took.
///   HOOK=.. MILL=.. QUOTE=.. SWAP_ROUTER=.. BUY_MILL=true AMOUNT_IN=1000000000000000 \
///     forge script script/Rehearsal.s.sol:SwapProbe --rpc-url rh --account deployer --sender 0x.. --broadcast
contract SwapProbe is PoolScript {
    function run() external {
        (PoolKey memory key, bool m0, Mill mill) = _key();
        PoolSwapTest swapRouter = PoolSwapTest(payable(vm.envAddress("SWAP_ROUTER")));
        bool buyMill = vm.envOr("BUY_MILL", true);
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        address vault = vm.envOr("VAULT", address(0));

        // zeroForOne buys currency1, so it buys the Mill exactly when the Mill is currency1.
        bool zeroForOne = buyMill ? !m0 : m0;

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        address inTok = zeroForOne ? c0 : c1;
        address outTok = zeroForOne ? c1 : c0;

        uint256 v0 = vault == address(0) ? 0 : IERC20(c0).balanceOf(vault);
        uint256 v1 = vault == address(0) ? 0 : IERC20(c1).balanceOf(vault);
        uint256 outBefore = IERC20(outTok).balanceOf(msg.sender);

        vm.startBroadcast();
        IERC20(inTok).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        console2.log("direction buysMill", buyMill);
        console2.log("zeroForOne        ", zeroForOne);
        console2.log("in                ", amountIn);
        console2.log("out               ", IERC20(outTok).balanceOf(msg.sender) - outBefore);
        if (vault != address(0)) {
            console2.log("vault +currency0  ", IERC20(c0).balanceOf(vault) - v0);
            console2.log("vault +currency1  ", IERC20(c1).balanceOf(vault) - v1);
        }
        console2.log("ratio now         ", mill.ratio());
    }
}

/// @notice Read-only. Pool price against backing — the number that says whether
///         the peg is holding and by how much it is off.
///   HOOK=.. MILL=.. QUOTE=.. forge script script/Rehearsal.s.sol:Report --rpc-url rh
contract Report is PoolScript {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external view {
        (PoolKey memory key, bool m0, Mill mill) = _key();
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(POOL_MANAGER).getSlot0(id);
        uint128 liquidity = IPoolManager(POOL_MANAGER).getLiquidity(id);

        (uint160 target,) = _backingSqrtPrice(mill, m0);

        console2.log("mill ratio (1e18) ", mill.ratio());
        console2.log("totalAssets       ", mill.totalAssets());
        console2.log("totalSupply       ", mill.totalSupply());
        console2.log("pending fees      ", mill.balanceOf(address(mill)));
        console2.log("totalBurned       ", mill.totalBurned());
        console2.log("");
        console2.log("pool tick         ", tick);
        console2.log("pool liquidity    ", liquidity);
        console2.log("sqrtPrice now     ", sqrtPriceX96);
        console2.log("sqrtPrice at ratio", target);

        // (P/P*) - 1 in bps, computed on the squared price so it is a real price gap.
        uint256 now2 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 tgt2 = Math.mulDiv(target, target, 1 << 96);
        uint256 gapBps = tgt2 == 0 ? 0 : (now2 > tgt2 ? ((now2 - tgt2) * 10_000) / tgt2 : ((tgt2 - now2) * 10_000) / tgt2);
        console2.log("gap vs backing bps", gapBps);
        // sqrtPriceX96 encodes currency1 per currency0, so a price ABOVE target
        // means currency0 buys more currency1 than backing says — currency1 is
        // CHEAP, not dear. The label used to say the opposite, which reads as an
        // emergency when the pool is at a premium and vice versa.
        console2.log(now2 >= tgt2 ? "  (currency1 cheaper than backing)" : "  (currency1 dearer than backing)");
        console2.log(
            (now2 >= tgt2) == m0 ? "  -> the milled token is at a PREMIUM" : "  -> the milled token is at a DISCOUNT"
        );
        console2.log(m0 ? "  currency0 IS the Mill" : "  currency1 IS the Mill");
    }
}
