// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SiphonToken} from "../src/SiphonToken.sol";
import {DeploySiphonToken} from "../script/DeploySiphonToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token from inside a contract so that the
/// constructor's `msg.sender` is a contract, exactly as it is at launch, and then forwards tokens
/// on request.
contract FactoryStub {
    SiphonToken public token;

    function launch() external returns (SiphonToken) {
        token = new SiphonToken();
        return token;
    }

    function forward(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SiphonTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    SiphonToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new SiphonToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SIPHON");
        assertEq(token.symbol(), "SIPH");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "SIPHON");
        assertEq(token.TOKEN_SYMBOL(), "SIPH");
        assertEq(token.DECIMALS(), 18);
    }

    function test_constantsMatchTheBrief() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsTransferFromZeroAndSupplyMinted() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit SiphonToken.SupplyMinted(alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new SiphonToken();
    }

    /// @dev At launch the deployer is a contract (the factory). The supply must land on it whole.
    function test_contractDeployerReceivesWholeSupply() public {
        FactoryStub factory = new FactoryStub();
        SiphonToken launched = factory.launch();
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);

        // The factory can forward any portion exactly, with no fee and no restriction.
        uint256 swarm = EXPECTED_SUPPLY / 10;
        assertTrue(factory.forward(alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY - swarm);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptFunctionDeploysToCaller() public {
        DeploySiphonToken script = new DeploySiphonToken();
        SiphonToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "SIPHON");
        assertEq(deployed.symbol(), "SIPH");
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        SiphonToken second = new SiphonToken();
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success paths
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234 ether;
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(stranger);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5 ether));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_chainOfTransfersIsLossless() public {
        uint256 amount = 777 ether;
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(stranger, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(stranger), amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure paths
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsWhenExceedingBalanceByOne() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 100 ether);
        assertTrue(token.approve(alice, 100 ether));
        assertEq(token.allowance(deployer, alice), 100 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 60 ether);
        assertEq(token.allowance(deployer, alice), 40 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5 ether, 6 ether)
        );
        token.transferFrom(deployer, bob, 6 ether);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, stranger, 1 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev `transferFrom` spends only the caller's allowance; the deployer gets no special pull.
    function test_deployerCannotPullWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Immutability: no mint, no burn, no admin
    // ---------------------------------------------------------------------------------------------

    /// @dev None of the usual supply-growing or admin selectors exist; every call reverts and the
    /// supply and balances are untouched, whether a stranger or the deployer calls.
    function test_noAdminOrMintSelectorExists() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        address[2] memory callers = [stranger, deployer];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], callers[c], type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
                assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
                assertEq(token.balanceOf(stranger), 0, signatures[i]);
                assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, signatures[i]);
            }
        }
    }

    function test_plainEtherTransferIsRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev The launch refuses DELEGATECALL, CALLCODE and SELFDESTRUCT in reachable runtime code.
    /// Mirrors the floor's scan: skip PUSH data, track reachability from JUMPDESTs.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + excess)
        );
        token.transfer(bob, held + excess);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowance_, uint256 spend) public {
        allowance_ = bound(allowance_, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, allowance_);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, spend));
        assertEq(token.balanceOf(bob), spend);
        assertEq(token.allowance(deployer, alice), allowance_ - spend);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromBeyondAllowanceReverts(uint256 allowance_, uint256 spend) public {
        allowance_ = bound(allowance_, 0, EXPECTED_SUPPLY - 1);
        spend = bound(spend, allowance_ + 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, spend)
        );
        token.transferFrom(deployer, bob, spend);
    }
}
