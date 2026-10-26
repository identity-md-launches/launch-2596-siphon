// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SiphonToken} from "../src/SiphonToken.sol";

/// @title DeploySiphonToken
/// @notice Reviewable deployment script. The IdentityMD launch deploys the token from its bytecode
/// through the factory, so this script is reference only: it documents that the token takes no
/// constructor arguments and that the whole supply lands on whichever address deploys it.
/// @dev `deploy()` is the function tests call directly; `run()` only wraps it in a broadcast.
/// Nothing here reads the environment.
contract DeploySiphonToken is Script {
    /// @notice Deploys the token. The caller of this function (under broadcast, the broadcaster)
    /// receives the whole supply.
    function deploy() public returns (SiphonToken token) {
        token = new SiphonToken();
    }

    function run() external returns (SiphonToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
