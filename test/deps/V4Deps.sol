// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

// v4-core's PoolManager pins =0.8.26 while everything of ours pins 0.8.28, so it
// cannot be imported directly. Pulling it in here forces Foundry to compile it as
// its own unit; the tests then reach it by artifact name through `deployCode`,
// which needs no import and therefore no shared pragma.
import {PoolManager} from "v4-core/src/PoolManager.sol";
