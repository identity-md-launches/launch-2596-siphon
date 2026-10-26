// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SiphonToken} from "../src/SiphonToken.sol";

/// @notice Drives the token with valid and invalid calls among several actors (including the token
/// contract itself as a receiver) and mirrors every balance and allowance in ghost state. Calls that
/// must revert are attempted too; any that succeed, and any successful call whose effect differs from
/// the ghost model, are counted as violations for the invariants to report.
contract SiphonGhostHandler is Test {
    uint256 internal constant MAX = type(uint256).max;

    SiphonToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public violations;
    uint256 public expectedReverts;
    uint256 public successfulMoves;

    constructor(SiphonToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(makeAddr("g-alice"));
        actors.push(makeAddr("g-bob"));
        actors.push(makeAddr("g-carol"));
        actors.push(address(token_));
        ghostBalance[deployer] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) violations++;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            successfulMoves++;
        } catch {
            violations++;
        }
    }

    /// @dev Over-balance transfer: must revert.
    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        excess = bound(excess, 1, MAX - held);
        vm.prank(from);
        try token.transfer(to, held + excess) {
            violations++;
        } catch {
            expectedReverts++;
        }
    }

    /// @dev Transfer to the zero address: must revert for any amount.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            violations++;
        } catch {
            expectedReverts++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = MAX;
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) violations++;
            ghostAllowance[owner][spender] = amount;
        } catch {
            violations++;
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = ghostBalance[owner] < allowed ? ghostBalance[owner] : allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) violations++;
            if (allowed != MAX) ghostAllowance[owner][spender] = allowed - amount;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            successfulMoves++;
        } catch {
            violations++;
        }
    }

    /// @dev Pull more than the allowance (but within balance where possible): must revert and leave
    /// the allowance as it was.
    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == MAX) return;
        excess = bound(excess, 1, MAX - allowed);
        vm.prank(spender);
        try token.transferFrom(owner, to, allowed + excess) {
            violations++;
        } catch {
            expectedReverts++;
        }
    }

    /// @dev Pull more than the owner holds under a sufficient allowance: must revert.
    function transferFromOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed <= held) return;
        excess = bound(excess, 1, allowed - held);
        vm.prank(spender);
        try token.transferFrom(owner, to, held + excess) {
            violations++;
        } catch {
            expectedReverts++;
        }
    }
}

contract SiphonTokenGhostInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    SiphonToken internal token;
    SiphonGhostHandler internal handler;

    function setUp() public {
        address deployer = makeAddr("g-deployer");
        vm.prank(deployer);
        token = new SiphonToken();
        handler = new SiphonGhostHandler(token, deployer);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_balancesMatchGhostAndSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 bal = token.balanceOf(a);
            assertEq(bal, handler.ghostBalance(a));
            sum += bal;
        }
        assertEq(sum, SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s));
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_noUnexpectedOutcome() public view {
        assertEq(handler.violations(), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }
}
