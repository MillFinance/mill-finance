// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mill} from "../src/Mill.sol";

/// @notice Deploys one Mill and, optionally, seeds it as the first depositor.
///
/// @dev Seeding matters. The ERC-4626 inflation attack only works against a
///      near-empty vault, so being the first depositor with a real amount
///      closes that window by size on top of the decimal-offset mitigation.
///      Do it in the same run as the deployment, not later.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url rh --account deployer --sender 0x<deployer> --broadcast -vvvv
///
/// The signer comes from the CLI, never from an env var — a key in an env var
/// lands in shell history and in Foundry's broadcast artifacts.
///
/// Required env:
///   ASSET            underlying TKN address
///   MILL_NAME        e.g. "Mill TKN"
///   MILL_SYMBOL      e.g. "mTKN"
///   FEE_RECIPIENT    where the non-burned share of fees goes
///   OWNER            can set burnBps / feeRecipient / wind-down. Use a multisig.
///
/// Optional env (defaults shown):
///   WRAP_FEE_BPS     25     0.25%
///   UNWRAP_FEE_BPS   50     0.50%
///   MIN_BURN_BPS     5000   immutable floor on the holder share
///   BURN_BPS         7000   burned, i.e. paid to holders via the ratio
///   LP_BPS           0      to LP_RECIPIENT; the remainder is protocol revenue
///   LP_RECIPIENT     =FEE_RECIPIENT  point at a staking contract when one exists
///   SEED_AMOUNT      0      underlying to wrap immediately (0 = skip)
contract Deploy is Script {
    /// @dev Reverts rather than truncating. An out-of-range bps value that is
    ///      silently cast is the one deployment mistake that cannot be undone.
    function _bps(string memory name, uint256 fallbackValue) internal view returns (uint16) {
        uint256 v = vm.envOr(name, fallbackValue);
        require(v <= 10_000, string.concat(name, " must be <= 10000"));
        return uint16(v);
    }

    function run() external returns (Mill mill) {
        address asset = vm.envAddress("ASSET");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address lpRecipient = vm.envOr("LP_RECIPIENT", feeRecipient);
        address owner = vm.envAddress("OWNER");
        string memory name_ = vm.envString("MILL_NAME");
        string memory symbol_ = vm.envString("MILL_SYMBOL");

        // Solidity does not check explicit downcasts, so uint16(70000) is 4464
        // and deploys quietly. MIN_BURN_BPS is immutable, which makes a typo
        // there permanent — a missed zero would fix the holder floor at 44.64%
        // instead of 70%, and 65536 would erase the floor entirely.
        uint16 wrapFee = _bps("WRAP_FEE_BPS", 25);
        uint16 unwrapFee = _bps("UNWRAP_FEE_BPS", 50);
        uint16 minBurn = _bps("MIN_BURN_BPS", 5_000);
        uint16 burn = _bps("BURN_BPS", 7_000);
        uint16 lpBps = _bps("LP_BPS", 0);
        uint256 seed = vm.envOr("SEED_AMOUNT", uint256(0));
        // Where the seed shares go. Never msg.sender by default: in a forge
        // script that is the --sender flag, or forge's own default caller if the
        // flag is omitted, which is an address with no known private key.
        address seedTo = seed > 0 ? vm.envAddress("SEED_RECIPIENT") : address(0);

        vm.startBroadcast();

        mill = new Mill(
            IERC20(asset), name_, symbol_, wrapFee, unwrapFee, minBurn, burn, lpBps, feeRecipient, lpRecipient, owner
        );

        if (seed > 0) {
            IERC20(asset).approve(address(mill), seed);
            mill.wrap(seed, seedTo);
        }

        vm.stopBroadcast();

        console2.log("Mill          ", address(mill));
        console2.log("asset         ", asset);
        console2.log("owner         ", owner);
        console2.log("feeRecipient  ", feeRecipient);
        console2.log("wrap/unwrap   ", wrapFee, unwrapFee);
        console2.log("minBurn/burn  ", minBurn, burn);
        console2.log("lpBps         ", lpBps);
        console2.log("lpRecipient   ", lpRecipient);
        console2.log("totalAssets   ", mill.totalAssets());
        console2.log("totalSupply   ", mill.totalSupply());
        console2.log("ratio (1e18)  ", mill.ratio());
    }
}

/// @notice Reads a deployed Mill. Run before and after anything, so you always
///         know the ratio you are about to initialise a pool at.
///
/// Usage:
///   MILL=0x... forge script script/Deploy.s.sol:Inspect --rpc-url $RPC_URL
contract Inspect is Script {
    function run() external view {
        Mill mill = Mill(vm.envAddress("MILL"));
        console2.log("totalAssets   ", mill.totalAssets());
        console2.log("totalSupply   ", mill.totalSupply());
        console2.log("ratio (1e18)  ", mill.ratio());
        console2.log("pending fees  ", mill.balanceOf(address(mill)));
        console2.log("totalBurned   ", mill.totalBurned());
        console2.log("burnBps       ", mill.burnBps());
        console2.log("wrapDisabled  ", mill.wrapDisabled());
    }
}
