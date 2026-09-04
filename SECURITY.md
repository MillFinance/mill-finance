# Security

Mill Finance is in beta and has **not** been audited by a third party. Treat
every deployment as experimental and do not deposit more than you are willing
to lose.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Email **security@millfinance.fun** with:

- what the bug is, and which contract and function it affects
- how to reproduce it - a failing Foundry test is ideal
- what an attacker gains, and roughly what it would cost them

You will get an acknowledgement within 72 hours. If you have not heard back in
that time, assume the mail did not arrive and reach out on the public channels
listed at millfinance.fun asking only for a contact - without describing the
bug.

## Scope

In scope: everything under `src/`.

Out of scope, though still worth telling us about: issues in Uniswap v4,
OpenZeppelin or Permit2 themselves; anything that requires the owner key to be
compromised; front-end issues that do not put funds at risk.

## What the owner can and cannot do

Reading this before reporting a "the owner can steal funds" issue will save us
both time.

The owner **can** move the fee split between the burn, the LP leg and the
protocol - but never below the immutable `minBurnBps` floor set at deployment -
change the two recipient addresses, and close the vault to new deposits.

The owner **cannot** touch the underlying, mint shares, change either fee
(both are immutable and capped at 1% in and 3% out), lower the burn floor, or
stop anyone unwrapping. Unwrapping cannot be paused or disabled by anybody.

## Known and accepted

- `Mill.transferOwnership` is single-step. A transfer to a wrong address
  permanently freezes the split, the recipients and the deposit switch. It
  cannot reach the underlying.
- The hook's fee vault is owner-set. A vault that reverts on receipt would
  revert every swap on that pool until the owner repoints it.
- Rewards accrued while the staking vault has no active positions sit in an
  `unallocated` bucket and can only be swept by the rescuer once the vault is
  provably empty.
