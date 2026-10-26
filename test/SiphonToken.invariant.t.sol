// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SiphonToken} from "../src/SiphonToken.sol";

/// @notice Drives transfers, approvals and transferFroms between a small set of actors, tracking
/// the sum of their balances so the invariant can check conservation.
contract SiphonHandler is Test {
    SiphonToken public immutable token;
    address[] public actors;

    constructor(SiphonToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(makeAddr("h-alice"));
        actors.push(makeAddr("h-bob"));
        actors.push(makeAddr("h-carol"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 cap = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract SiphonTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    SiphonToken internal token;
    SiphonHandler internal handler;

    function setUp() public {
        address deployer = makeAddr("inv-deployer");
        vm.prank(deployer);
        token = new SiphonToken();
        handler = new SiphonHandler(token, deployer);
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function invariant_actorBalancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, EXPECTED_SUPPLY);
    }
}
