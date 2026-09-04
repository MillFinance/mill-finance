// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

// v4-periphery's PositionManager, pulled in so Foundry compiles it as its own
// unit. The tests reach it by artifact name through `deployCode`, which needs no
// import and therefore no shared pragma.
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
