// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Mill} from "../src/Mill.sol";

/// @title  Know the token before you wrap it
///
/// @notice Launchpad tokens are not plain ERC-20s. Transfer taxes, max-wallet
///         caps, max-tx caps, blacklists, trading-enabled switches and
///         rebasing balances all exist in the wild, and every one of them
///         changes what a wrapper around that token does.
///
///         A transfer tax is survivable — the Mill credits the balance delta,
///         not the argument. A max-wallet cap is not: the vault becomes the
///         largest holder by design, so a cap smaller than your intended TVL
///         is a hard stop, and you find that out at the size where it hurts.
///
///         Run this BEFORE deploying a Mill over any token you did not write.
///
///   TOKEN=0x... HOLDER=0x<an address holding some> \
///     RH_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-contract TokenReconTest -vv
///
/// @dev HOLDER is optional; without it the test tries `deal`, which works on
///      tokens with conventional balance storage and silently misreports on
///      those without. If `deal` is used, the FoT and cap findings are still
///      valid but the "can I actually get these tokens" question is not tested.
contract TokenReconTest is Test {
    IERC20 token;
    uint8 dec;
    uint256 unit;
    address holder;
    bool usedDeal;

    address sink = address(0x5115);
    address treasury = address(0x7EEA);

    /// @dev This suite reconnoitres one specific token on a fork, so it only has
    ///      meaning when TOKEN is set. It used to fail a plain `forge test` for
    ///      everyone else, which trains you to ignore a red line in the summary
    ///      — the one habit a test suite must never teach.
    bool armed;

    modifier onlyArmed() {
        if (!armed) return;
        _;
    }

    function setUp() public {
        address t = vm.envOr("TOKEN", address(0));
        if (t == address(0)) {
            console2.log("TokenRecon: skipped. Set TOKEN=0x.. and RH_RPC to run it.");
            return;
        }
        vm.createSelectFork(vm.envString("RH_RPC"));
        token = IERC20(t);
        holder = vm.envOr("HOLDER", address(0));
        armed = true;
    }

    function _decimals() internal view returns (uint8) {
        try IERC20Metadata(address(token)).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 255;
        }
    }

    function _name() internal view returns (string memory) {
        try IERC20Metadata(address(token)).name() returns (string memory n) {
            return n;
        } catch {
            return "<no name()>";
        }
    }

    function _symbol() internal view returns (string memory) {
        try IERC20Metadata(address(token)).symbol() returns (string memory s) {
            return s;
        } catch {
            return "<no symbol()>";
        }
    }

    // -----------------------------------------------------------------
    // 1. what is this thing
    // -----------------------------------------------------------------

    function test_01_Metadata() public  onlyArmed {
        assertGt(address(token).code.length, 0, "TOKEN has no code");
        dec = _decimals();
        unit = dec == 255 ? 1e18 : 10 ** dec;

        console2.log("token        ", address(token));
        console2.log("name         ", _name());
        console2.log("symbol       ", _symbol());
        console2.log("decimals     ", dec);
        console2.log("totalSupply  ", token.totalSupply());
        console2.log("code size    ", address(token).code.length);

        assertTrue(dec != 255, "no decimals(); the Mill would assume 18");
        assertGt(token.totalSupply(), 0, "zero supply");
    }

    // -----------------------------------------------------------------
    // 2. does a plain transfer deliver what it says
    // -----------------------------------------------------------------

    /// @dev Prefers a real holder — that proves the balance is actually spendable,
    ///      which `deal` never can. Falls back to `deal` when the holder is short,
    ///      because the cap check below needs 1% of supply and nobody hands you that.
    function _grab(uint256 amount) internal returns (address from) {
        dec = _decimals();
        unit = 10 ** dec;

        if (holder != address(0) && token.balanceOf(holder) >= amount) {
            usedDeal = false;
            return holder;
        }

        if (holder != address(0)) {
            console2.log("HOLDER balance is short of", amount);
            console2.log("HOLDER holds             ", token.balanceOf(holder));
            console2.log("falling back to deal() for this check");
        }

        usedDeal = true;
        address a = address(0xA11CE);
        deal(address(token), a, amount);
        require(
            token.balanceOf(a) >= amount,
            "deal() did not work on this token and HOLDER is short; find a whale address"
        );
        return a;
    }

    function test_02_TransferTax() public  onlyArmed {
        uint256 amount = 100 * 10 ** _decimals();
        address from = _grab(amount);

        uint256 before_ = token.balanceOf(sink);
        vm.prank(from);
        token.transfer(sink, amount);
        uint256 got = token.balanceOf(sink) - before_;

        uint256 taxBps = got >= amount ? 0 : ((amount - got) * 10_000) / amount;
        console2.log("funded via deal()", usedDeal);
        console2.log("sent             ", amount);
        console2.log("received         ", got);
        console2.log("transfer tax bps ", taxBps);

        if (taxBps > 0) {
            console2.log(">>> THIS TOKEN TAXES TRANSFERS.");
            console2.log(">>> The Mill survives it (it credits the balance delta), but every");
            console2.log(">>> wrap and unwrap pays it on top of the toll, and it widens the");
            console2.log(">>> arb band by 2x the tax on every round trip.");
        }
    }

    // -----------------------------------------------------------------
    // 3. is there a cap that stops the vault growing
    // -----------------------------------------------------------------

    /// @dev The vault is the largest holder by construction. A max-wallet cap
    ///      set as a fraction of supply is a ceiling on TVL, and you hit it at
    ///      exactly the moment the protocol is working.
    function test_03_LargeTransferSucceeds() public  onlyArmed {
        uint256 big = token.totalSupply() / 100; // 1% of supply
        address from = _grab(big);

        vm.prank(from);
        try token.transfer(sink, big) {
            console2.log("1% of supply moved in one transfer: OK");
            console2.log("received        ", token.balanceOf(sink));
        } catch Error(string memory reason) {
            console2.log(">>> 1% of supply REVERTED:", reason);
            console2.log(">>> Likely a max-tx or max-wallet cap. That caps your TVL.");
            fail();
        } catch {
            console2.log(">>> 1% of supply REVERTED with no reason string.");
            console2.log(">>> Likely a max-tx or max-wallet cap. That caps your TVL.");
            fail();
        }
    }

    // -----------------------------------------------------------------
    // 4. does the Mill actually work over it, end to end
    // -----------------------------------------------------------------

    function test_04_MillRoundTrip() public  onlyArmed {
        uint256 amount = 1000 * 10 ** _decimals();
        address from = _grab(amount);

        Mill mill =
            new Mill(token, "Mill Rehearsal", "mREH", 25, 50, 5_000, 7_000, 0, treasury, treasury, address(this));

        vm.startPrank(from);
        token.approve(address(mill), type(uint256).max);
        uint256 shares = mill.wrap(amount, from);
        vm.stopPrank();

        console2.log("wrapped          ", amount);
        console2.log("shares out       ", shares);
        console2.log("mill decimals    ", mill.decimals());
        console2.log("totalAssets      ", mill.totalAssets());
        console2.log("ratio            ", mill.ratio());

        mill.processFees();
        console2.log("ratio post-burn  ", mill.ratio());
        assertGt(mill.ratio(), 1e18, "ratio did not rise after the first toll");

        vm.prank(from);
        uint256 out = mill.unwrap(shares, from);
        console2.log("unwrapped back   ", out);
        assertGt(out, 0, "unwrap returned nothing");

        uint256 roundTripBps = amount > out ? ((amount - out) * 10_000) / amount : 0;
        console2.log("wrap+unwrap cost bps (incl. any token tax):", roundTripBps);
    }

    // -----------------------------------------------------------------
    // 5. can the token's owner turn it off underneath you
    // -----------------------------------------------------------------

    /// @dev Informational, and it never fails. An owner that can pause trading,
    ///      blacklist, or re-tax is a live counterparty sitting under the vault.
    ///      Renounced ownership is not proof of safety, but its absence is a
    ///      reason to read the source before wrapping anything real.
    function test_05_OwnershipSurface() public view onlyArmed {
        string[6] memory sigs =
            ["owner()", "getOwner()", "paused()", "tradingEnabled()", "maxWalletAmount()", "maxTxAmount()"];

        for (uint256 i; i < sigs.length; i++) {
            (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeWithSignature(sigs[i]));
            if (ok && ret.length >= 32) {
                console2.log(sigs[i], uint256(bytes32(ret)));
            } else {
                console2.log(sigs[i], "-- absent");
            }
        }
        console2.log("");
        console2.log("Anything non-zero above is a switch someone else holds.");
    }

    // -----------------------------------------------------------------
    // 6. are the caps actually enforced, or vestigial getters
    // -----------------------------------------------------------------

    /// @dev A `maxWalletAmount()` that still returns a number is not the same as
    ///      one that still reverts. Launchpad tokens routinely lift their limits
    ///      after launch and leave the getter behind. The only way to know is to
    ///      exceed it. If it bites, that number is a hard ceiling on vault TVL,
    ///      because the vault is the largest holder by design.
    function test_06_AreTheCapsLive() public  onlyArmed {
        (bool okW, bytes memory retW) =
            address(token).staticcall(abi.encodeWithSignature("maxWalletAmount()"));
        if (!okW || retW.length < 32) {
            console2.log("no maxWalletAmount(); nothing to test");
            return;
        }
        uint256 maxWallet = uint256(bytes32(retW));
        if (maxWallet == 0 || maxWallet >= token.totalSupply()) {
            console2.log("maxWalletAmount is unset or >= supply; not a constraint");
            return;
        }

        uint256 over = maxWallet + (maxWallet / 10); // 10% past the cap
        address from = _grab(over);
        address fresh = address(0xCA9);

        console2.log("maxWalletAmount ", maxWallet);
        console2.log("attempting      ", over);

        vm.prank(from);
        try token.transfer(fresh, over) {
            uint256 landed = token.balanceOf(fresh);
            if (landed >= over) {
                console2.log(">>> CAP IS NOT ENFORCED. The getter is vestigial.");
                console2.log(">>> Vault TVL is unconstrained by it.");
            } else {
                console2.log(">>> transfer succeeded but only", landed, "landed");
                console2.log(">>> something silently trims transfers; read the source.");
            }
        } catch {
            console2.log(">>> CAP IS LIVE. Transfers above it revert.");
            console2.log(">>> Vault TVL on this token stops at maxWalletAmount.");
            console2.log(">>> Fine for a rehearsal. Never ship the real TKN with this.");
        }
    }
}
