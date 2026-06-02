// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PToken} from "../../src/tokens/PToken.sol";
import {NToken} from "../../src/tokens/NToken.sol";

/// @title  TokensTest
/// @notice Unit tests for PToken and NToken.
///         Focus: mint/burn access control and basic ERC-20 properties.
contract TokensTest is Test {
    address internal constant TRANCHER = address(0x1111111111111111111111111111111111111111);
    address internal ALICE;
    address internal BOB;

    PToken internal pToken;
    NToken internal nToken;

    function setUp() public {
        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");
        pToken = new PToken(TRANCHER);
        nToken = new NToken(TRANCHER);
    }

    /* ///////////////////////////////////////////////////////////////
                             METADATA
    /////////////////////////////////////////////////////////////// */

    function test_PToken_NameAndSymbol() public view {
        assertEq(pToken.name(), "OptionZero Principal Token");
        assertEq(pToken.symbol(), "ozP");
    }

    function test_NToken_NameAndSymbol() public view {
        assertEq(nToken.name(), "OptionZero Net-Delta Token");
        assertEq(nToken.symbol(), "ozN");
    }

    function test_Decimals_DefaultTo18() public view {
        assertEq(pToken.decimals(), 18);
        assertEq(nToken.decimals(), 18);
    }

    /* ///////////////////////////////////////////////////////////////
                     ACCESS CONTROL — ONLY TRANCHER MINTS
    /////////////////////////////////////////////////////////////// */

    function test_PToken_MintByTrancher_Succeeds() public {
        vm.prank(TRANCHER);
        pToken.mint(ALICE, 1_000e18);
        assertEq(pToken.balanceOf(ALICE), 1_000e18);
        assertEq(pToken.totalSupply(), 1_000e18);
    }

    function test_NToken_MintByTrancher_Succeeds() public {
        vm.prank(TRANCHER);
        nToken.mint(BOB, 500e18);
        assertEq(nToken.balanceOf(BOB), 500e18);
    }

    function test_PToken_MintByNonTrancher_Reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PToken.PToken_OnlyTrancher.selector, ALICE));
        pToken.mint(ALICE, 1_000e18);
    }

    function test_NToken_MintByNonTrancher_Reverts() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(NToken.NToken_OnlyTrancher.selector, BOB));
        nToken.mint(BOB, 500e18);
    }

    /* ///////////////////////////////////////////////////////////////
                     ACCESS CONTROL — ONLY TRANCHER BURNS
    /////////////////////////////////////////////////////////////// */

    function test_PToken_BurnByTrancher_Succeeds() public {
        vm.startPrank(TRANCHER);
        pToken.mint(ALICE, 1_000e18);
        pToken.burn(ALICE, 400e18);
        vm.stopPrank();

        assertEq(pToken.balanceOf(ALICE), 600e18);
        assertEq(pToken.totalSupply(), 600e18);
    }

    function test_NToken_BurnByTrancher_Succeeds() public {
        vm.startPrank(TRANCHER);
        nToken.mint(BOB, 500e18);
        nToken.burn(BOB, 500e18);
        vm.stopPrank();

        assertEq(nToken.balanceOf(BOB), 0);
    }

    function test_PToken_BurnByNonTrancher_Reverts() public {
        vm.prank(TRANCHER);
        pToken.mint(ALICE, 1_000e18);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PToken.PToken_OnlyTrancher.selector, ALICE));
        pToken.burn(ALICE, 100e18);
    }

    function test_NToken_BurnByNonTrancher_Reverts() public {
        vm.prank(TRANCHER);
        nToken.mint(BOB, 500e18);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(NToken.NToken_OnlyTrancher.selector, BOB));
        nToken.burn(BOB, 100e18);
    }

    /* ///////////////////////////////////////////////////////////////
                         BURN MORE THAN BALANCE
    /////////////////////////////////////////////////////////////// */

    function test_PToken_BurnExceedingBalance_Reverts() public {
        vm.startPrank(TRANCHER);
        pToken.mint(ALICE, 100e18);
        // Solady ERC20 reverts on underflow.
        vm.expectRevert();
        pToken.burn(ALICE, 101e18);
        vm.stopPrank();
    }

    /* ///////////////////////////////////////////////////////////////
                         STANDARD ERC-20 TRANSFERS
    /////////////////////////////////////////////////////////////// */

    function test_PToken_TransferBetweenUsers() public {
        vm.prank(TRANCHER);
        pToken.mint(ALICE, 1_000e18);

        vm.prank(ALICE);
        pToken.transfer(BOB, 250e18);

        assertEq(pToken.balanceOf(ALICE), 750e18);
        assertEq(pToken.balanceOf(BOB), 250e18);
    }

    /* ///////////////////////////////////////////////////////////////
                            IMMUTABLE ADDRESS
    /////////////////////////////////////////////////////////////// */

    function test_Trancher_AddressIsImmutable() public view {
        assertEq(pToken.trancher(), TRANCHER);
        assertEq(nToken.trancher(), TRANCHER);
    }

    /* ///////////////////////////////////////////////////////////////
                              FUZZ TESTS
    /////////////////////////////////////////////////////////////// */

    function testFuzz_MintAndBurn(uint128 amount) public {
        vm.assume(amount > 0);

        vm.startPrank(TRANCHER);
        pToken.mint(ALICE, amount);
        assertEq(pToken.balanceOf(ALICE), amount);

        pToken.burn(ALICE, amount);
        assertEq(pToken.balanceOf(ALICE), 0);
        vm.stopPrank();
    }
}
