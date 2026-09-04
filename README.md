# Mill Finance

The contracts and front end behind [millfinance.fun](https://millfinance.fun),
on Robinhood Chain (chain id 4663).

Mill wraps an ordinary ERC-20 into a *milled* token that is a permanent claim on
it. Wrapping and unwrapping each pay a small fee, taken in shares, and most of
that fee is burned - which raises what every remaining share redeems for. The
redemption ratio only ever goes up. Mill is an openly derivative fork of
[Peapods Finance](https://peapods.finance).

**This is beta software and has not been audited.** Do not deposit more than you
are willing to lose. See [SECURITY.md](SECURITY.md) for what the owner can and
cannot do, and how to report a vulnerability.

## Layout

| | |
|---|---|
| `src/Mill.sol` | the vault, and the milled ERC-20 itself |
| `src/MillLPStaking.sol` | stake a v4 liquidity position, earn the LP share of the fee |
| `src/DirectionalFeeHook.sol` | a Uniswap v4 hook charging a fee on one swap direction |
| `src/MillLens.sol` | read-only helper the front end uses |
| `src/MillPoolMath.sol` | opening-price arithmetic for a new pool |
| `src/HookMiner.sol` | CREATE2 salt search for a hook address with the right permission bits |
| `script/` | deployment and rehearsal scripts |
| `test/` | the test suite |
| `web/index.html` | the entire front end, one self-contained file |

## Build

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recurse-submodules https://github.com/YOURNAME/mill-finance
cd mill-finance
forge test
```

If you cloned without `--recurse-submodules`, run `git submodule update --init
--recursive` first.

The project needs two compilers - v4-core pins `0.8.26` and our own contracts
pin `0.8.28` - so `foundry.toml` deliberately sets no `solc` version. Foundry
fetches both.

## Front end

`web/index.html` is the whole application: no build step, no framework, no
dependencies. Serve it and open it.

```bash
cd web && python3 -m http.server 8013
```

`publish.sh` deploys it to Cloudflare Pages. It uploads that one file and
nothing else, and it strips any vault from the published build whose address is
not listed in `publish.allow`.

## Licence

Per-file `SPDX-License-Identifier` headers govern. Most of the code is MIT;
`src/DirectionalFeeHook.sol` is GPL-2.0-or-later, inherited from the Uniswap v4
code it builds on.
