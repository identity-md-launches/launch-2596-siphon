// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SiphonToken} from "../src/SiphonToken.sol";

/// @notice Deploys the token through CREATE2 and splits the supply in the same call, the way the
/// launch factory does in one transaction.
contract Create2Launcher {
    function launchAndSplit(bytes32 salt, address distributor, address pool, address remainderTo)
        external
        returns (SiphonToken token)
    {
        token = new SiphonToken{salt: salt}();
        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * 1_000) / 10_000;
        uint256 seed = (supply * 8_800) / 10_000;
        require(token.transfer(distributor, swarm), "swarm");
        require(token.transfer(pool, seed), "seed");
        require(token.transfer(remainderTo, supply - swarm - seed), "remainder");
    }
}

/// @notice Edge inputs the first suite does not pin: zero amounts, zero addresses, self-allowances,
/// overwritten approvals, the full supply through `transferFrom`, return data and event shape.
contract SiphonTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("edge-deployer");
    address internal alice = makeAddr("edge-alice");
    address internal bob = makeAddr("edge-bob");

    SiphonToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new SiphonToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @dev The constructor emits exactly two logs (Transfer and SupplyMinted) and nothing else.
    function test_constructorEmitsExactlyTwoLogs() public {
        vm.recordLogs();
        vm.prank(alice);
        SiphonToken t = new SiphonToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(t));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(logs[1].topics[0], SiphonToken.SupplyMinted.selector);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[1].data, (uint256)), SUPPLY);
    }

    /// @dev Deploy and split in one call through CREATE2: every launch flow arrives exact and the
    /// three shares add back to the supply with nothing left on the launcher.
    function test_create2LaunchSplitIsExact() public {
        Create2Launcher launcher = new Create2Launcher();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainderTo = makeAddr("remainder");
        bytes32 salt = bytes32(uint256(42));
        address predicted = vm.computeCreate2Address(salt, keccak256(type(SiphonToken).creationCode), address(launcher));
        SiphonToken t = launcher.launchAndSplit(salt, distributor, pool, remainderTo);
        assertEq(address(t), predicted);
        assertEq(t.balanceOf(distributor), SUPPLY / 10);
        assertEq(t.balanceOf(pool), (SUPPLY * 88) / 100);
        assertEq(t.balanceOf(remainderTo), (SUPPLY * 2) / 100);
        assertEq(t.balanceOf(address(launcher)), 0);
        assertEq(t.totalSupply(), SUPPLY);
    }

    /// @dev The same salt from the same launcher cannot deploy a second token over the first.
    function test_create2SameSaltTwiceReverts() public {
        Create2Launcher launcher = new Create2Launcher();
        bytes32 salt = bytes32(uint256(7));
        launcher.launchAndSplit(salt, alice, bob, deployer);
        vm.expectRevert();
        launcher.launchAndSplit(salt, alice, bob, deployer);
    }

    // ---------------------------------------------------------------------------------------------
    // Return data and unknown calls
    // ---------------------------------------------------------------------------------------------

    function test_transferReturnsExactlyOneTrueWord() public {
        vm.prank(deployer);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function test_unknownSelectorRevertsWithEmptyData() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_emptyCalldataWithoutValueReverts() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------------------------------------
    // Zero amounts and zero addresses
    // ---------------------------------------------------------------------------------------------

    /// @dev A zero-amount `transferFrom` needs no allowance and moves nothing, but still emits.
    function test_transferFromZeroWithoutAllowanceSucceeds() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, bob, 0);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0);
    }

    /// @dev Nothing can be pulled from the zero address, not even zero tokens.
    function test_transferFromZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    /// @dev A pull to the zero address reverts and the whole call unwinds: allowance and balances
    /// are untouched.
    function test_transferFromToZeroAddressRevertsAndKeepsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
        assertEq(token.allowance(deployer, alice), 10 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    /// @dev Tokens sent to the token contract itself are accepted and stranded: no recovery path.
    function test_transferToTokenContractIsAcceptedAndStranded() public {
        vm.prank(deployer);
        token.transfer(address(token), 3 ether);
        assertEq(token.balanceOf(address(token)), 3 ether);
        assertEq(token.allowance(address(token), deployer), 0);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(address(token), deployer, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance semantics
    // ---------------------------------------------------------------------------------------------

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 2 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 2 ether, 3 ether)
        );
        token.transferFrom(deployer, bob, 3 ether);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev An allowance is per (owner, spender): one spender's approval gives another nothing.
    function test_allowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.allowance(alice, deployer), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Spending an allowance exactly to zero works once and then refuses one more wei.
    function test_allowanceSpentExactlyThenExhausted() public {
        vm.prank(deployer);
        token.approve(alice, 4 ether);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, 4 ether);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
    }

    /// @dev OZ v5 does not emit Approval when `transferFrom` spends an allowance.
    function test_transferFromEmitsOnlyTransfer() public {
        vm.prank(deployer);
        token.approve(alice, 4 ether);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
    }

    /// @dev Pulling your own tokens still needs a self-allowance.
    function test_selfTransferFromNeedsSelfAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);

        vm.startPrank(deployer);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.stopPrank();
        assertEq(token.allowance(deployer, deployer), 0);
        assertEq(token.balanceOf(alice), 1);
    }

    /// @dev The full supply moves in one `transferFrom` under an infinite allowance.
    function test_fullSupplyThroughTransferFrom() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, SUPPLY);
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev An allowance larger than the balance does not let a spender take more than the balance.
    function test_allowanceAboveBalanceIsCappedByBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1 ether, 1 ether + 1)
        );
        token.transferFrom(alice, bob, 1 ether + 1);
        assertEq(token.allowance(alice, bob), 100 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveStoresExactValue(address owner, address spender, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(owner, spender, amount);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotMoveAnything(address stranger, uint256 amount) public {
        stranger = address(uint160(bound(uint160(stranger), 1, type(uint160).max)));
        vm.assume(stranger != deployer);
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, amount));
        token.transfer(alice, amount);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoHopTransferConserves(address mid, address to, uint256 a, uint256 b) public {
        mid = address(uint160(bound(uint160(mid), 1, type(uint160).max)));
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        vm.assume(mid != deployer && to != deployer && mid != to);
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        vm.prank(deployer);
        token.transfer(mid, a);
        vm.prank(mid);
        token.transfer(to, b);
        assertEq(token.balanceOf(deployer), SUPPLY - a);
        assertEq(token.balanceOf(mid), a - b);
        assertEq(token.balanceOf(to), b);
        assertEq(token.balanceOf(deployer) + token.balanceOf(mid) + token.balanceOf(to), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_infiniteAllowanceNeverDecrements(uint256 x, uint256 y) public {
        x = bound(x, 0, SUPPLY);
        y = bound(y, 0, SUPPLY - x);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, x);
        token.transferFrom(deployer, bob, y);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), x + y);
    }

    /// @dev Just below infinite is a finite allowance and does decrement.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nearMaxAllowanceDecrements(uint256 spend) public {
        spend = bound(spend, 1, SUPPLY);
        uint256 allowed = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(deployer, bob, spend);
        assertEq(token.allowance(deployer, alice), allowed - spend);
    }
}
