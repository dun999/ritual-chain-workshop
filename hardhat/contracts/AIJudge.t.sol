// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudge} from "./AIJudge.sol";

/// @dev Mimics the LLM_INFERENCE_PRECOMPILE (0x0802) response shape documented
///      in PrecompileConsumer._executePrecompile: raw return data must decode
///      as (bytes simmedInput, bytes actualOutput), where actualOutput decodes
///      as (bool hasError, bytes completionData, bytes, string errorMessage,
///      AIJudge.ConvoHistory). A `fallback(bytes calldata) returns (bytes memory)`
///      passes its return value through as raw returndata (no extra ABI
///      wrapping), so this reproduces the real precompile's wire format.
///
///      The completion text is a hardcoded literal (not a constructor arg /
///      storage variable) because `vm.etch` only copies *code*, not storage --
///      a literal embedded in the fallback body is part of the runtime code
///      and survives `vm.etch`, whereas a state variable would not.
contract MockLLMPrecompileSuccess {
    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory completion = bytes(
            '{"winnerIndex":1,"ranking":[{"index":1,"score":95,"reason":"clean and correct"}],"summary":"Submission 1 wins"}'
        );
        bytes memory inner = abi.encode(
            false,
            completion,
            bytes(""),
            "",
            AIJudge.ConvoHistory("", "", "")
        );
        return abi.encode(input, inner);
    }
}

contract MockLLMPrecompileError {
    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory inner = abi.encode(
            true,
            bytes(""),
            bytes(""),
            "model overloaded",
            AIJudge.ConvoHistory("", "", "")
        );
        return abi.encode(input, inner);
    }
}

contract AIJudgeTest is Test {
    address constant LLM_PRECOMPILE = address(0x0802);

    AIJudge judge;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address eve = makeAddr("eve");

    uint256 submissionDeadline;
    uint256 revealDeadline;

    function setUp() public {
        judge = new AIJudge();
        submissionDeadline = block.timestamp + 1 days;
        revealDeadline = block.timestamp + 2 days;

        vm.deal(owner, 10 ether);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _createBounty() internal returns (uint256 bountyId) {
        vm.prank(owner);
        bountyId = judge.createBounty{value: 1 ether}(
            "Best oracle design",
            "Judge on correctness and gas efficiency.",
            submissionDeadline,
            revealDeadline
        );
    }

    function _commitment(
        string memory answer,
        bytes32 salt,
        address who,
        uint256 bountyId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, who, bountyId));
    }

    bytes constant SUCCESS_COMPLETION =
        '{"winnerIndex":1,"ranking":[{"index":1,"score":95,"reason":"clean and correct"}],"summary":"Submission 1 wins"}';

    /// @dev Installs a mock at the LLM precompile address returning a fixed
    ///      successful completion, so judgeAll() can run end-to-end locally.
    function _etchSuccessPrecompile() internal {
        MockLLMPrecompileSuccess mock = new MockLLMPrecompileSuccess();
        vm.etch(LLM_PRECOMPILE, address(mock).code);
    }

    function _etchErrorPrecompile() internal {
        MockLLMPrecompileError mock = new MockLLMPrecompileError();
        vm.etch(LLM_PRECOMPILE, address(mock).code);
    }

    function _longAnswer() internal pure returns (string memory) {
        bytes memory b = new bytes(2001);
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = "a";
        }
        return string(b);
    }

    // ------------------------------------------------------------------
    // Full happy path
    // ------------------------------------------------------------------

    function test_FullLifecycle_JudgesAndPaysWinner() public {
        uint256 bountyId = _createBounty();

        bytes32 saltA = keccak256("salt-alice");
        bytes32 saltB = keccak256("salt-bob");
        bytes32 saltC = keccak256("salt-carol");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("alice answer", saltA, alice, bountyId));
        vm.prank(bob);
        judge.submitCommitment(bountyId, _commitment("bob answer", saltB, bob, bountyId));
        vm.prank(carol);
        judge.submitCommitment(bountyId, _commitment("carol answer", saltC, carol, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltA);
        vm.prank(bob);
        judge.revealAnswer(bountyId, "bob answer", saltB);
        // Carol never reveals -- must be excluded from judging and payout.

        vm.warp(revealDeadline + 1);

        _etchSuccessPrecompile();

        vm.prank(owner);
        judge.judgeAll(bountyId, "encoded-llm-request");

        uint256 bobBalanceBefore = bob.balance;

        // index 1 in the *revealed* list is bob (alice=0, bob=1); carol never
        // entered the submissions array at all.
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 1);

        assertEq(bob.balance, bobBalanceBefore + 1 ether);

        (
            ,
            ,
            ,
            uint256 reward,
            ,
            ,
            bool judged,
            bool finalized,
            uint256 commitmentCount,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        ) = judge.getBounty(bountyId);

        assertEq(reward, 0);
        assertTrue(judged);
        assertTrue(finalized);
        assertEq(commitmentCount, 3);
        assertEq(submissionCount, 2);
        assertEq(winnerIndex, 1);
        assertEq(aiReview, SUCCESS_COMPLETION);

        (address submitter1, string memory answer1) = judge.getSubmission(bountyId, 1);
        assertEq(submitter1, bob);
        assertEq(answer1, "bob answer");
    }

    function test_JudgeAll_RevertsAndDoesNotMarkJudged_WhenAiErrors() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "ans", salt);
        vm.warp(revealDeadline + 1);

        _etchErrorPrecompile();

        vm.prank(owner);
        vm.expectRevert(bytes("model overloaded"));
        judge.judgeAll(bountyId, "encoded-llm-request");

        (, , , , , , bool judged, , , , , ) = judge.getBounty(bountyId);
        assertFalse(judged);
    }

    // ------------------------------------------------------------------
    // Bounty creation rules
    // ------------------------------------------------------------------

    function test_RevertWhen_CreateBountyWithoutReward() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reward required"));
        judge.createBounty{value: 0}("t", "r", submissionDeadline, revealDeadline);
    }

    function test_RevertWhen_RevealDeadlineNotAfterSubmissionDeadline() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reveal deadline must be after submission deadline"));
        judge.createBounty{value: 1 ether}("t", "r", submissionDeadline, submissionDeadline);
    }

    // ------------------------------------------------------------------
    // Commit phase rules
    // ------------------------------------------------------------------

    function test_RevertWhen_CommitAfterSubmissionDeadline() public {
        uint256 bountyId = _createBounty();
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("submission phase closed"));
        judge.submitCommitment(bountyId, keccak256("x"));
    }

    function test_RevertWhen_DoubleCommitment() public {
        uint256 bountyId = _createBounty();

        vm.prank(alice);
        judge.submitCommitment(bountyId, keccak256("first"));

        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(bountyId, keccak256("second"));
    }

    function test_RevertWhen_TooManySubmissions() public {
        uint256 bountyId = _createBounty();

        for (uint256 i = 1; i <= judge.MAX_SUBMISSIONS(); i++) {
            address participant = vm.addr(i);
            vm.prank(participant);
            judge.submitCommitment(bountyId, keccak256(abi.encodePacked(i)));
        }

        address overflow = vm.addr(judge.MAX_SUBMISSIONS() + 1);
        vm.prank(overflow);
        vm.expectRevert(bytes("too many submissions"));
        judge.submitCommitment(bountyId, keccak256("overflow"));
    }

    // ------------------------------------------------------------------
    // Reveal phase rules
    // ------------------------------------------------------------------

    function test_RevertWhen_RevealBeforeSubmissionDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));

        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase not open yet"));
        judge.revealAnswer(bountyId, "ans", salt);
    }

    function test_RevertWhen_RevealAfterRevealDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));

        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase closed"));
        judge.revealAnswer(bountyId, "ans", salt);
    }

    function test_RevertWhen_RevealWithoutCommitment() public {
        uint256 bountyId = _createBounty();
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("no commitment"));
        judge.revealAnswer(bountyId, "ans", keccak256("s"));
    }

    function test_RevertWhen_RevealMismatchedAnswer() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("real answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "different answer", salt);
    }

    function test_RevertWhen_RevealWrongSalt() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("real answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "real answer", keccak256("wrong-salt"));
    }

    function test_RevertWhen_DoubleReveal() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "ans", salt);

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(bountyId, "ans", salt);
    }

    function test_RevertWhen_AnswerTooLong() public {
        uint256 bountyId = _createBounty();
        string memory longAnswer = _longAnswer();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment(longAnswer, salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("answer too long"));
        judge.revealAnswer(bountyId, longAnswer, salt);
    }

    /// @notice Eve copies Alice's exact commitment hash and tries to reveal
    ///         Alice's answer under her own address. Because the commitment
    ///         formula binds msg.sender, Eve's recomputed hash (with sender =
    ///         eve) never matches Alice's original commitment.
    function test_RevertWhen_CopyCatCannotStealCommitment() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("alice answer", salt, alice, bountyId));

        vm.prank(eve);
        judge.submitCommitment(bountyId, _commitment("alice answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(eve);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "alice answer", salt);
    }

    // ------------------------------------------------------------------
    // Judging rules
    // ------------------------------------------------------------------

    function test_RevertWhen_JudgeBeforeRevealDeadline() public {
        uint256 bountyId = _createBounty();

        vm.prank(owner);
        vm.expectRevert(bytes("reveal phase not over"));
        judge.judgeAll(bountyId, "");
    }

    function test_RevertWhen_JudgeByNonOwner() public {
        uint256 bountyId = _createBounty();
        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(bountyId, "");
    }

    function test_RevertWhen_JudgeWithNoRevealedSubmissions() public {
        uint256 bountyId = _createBounty();
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        vm.expectRevert(bytes("no revealed submissions"));
        judge.judgeAll(bountyId, "");
    }

    function test_RevertWhen_JudgeTwice() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "ans", salt);
        vm.warp(revealDeadline + 1);

        _etchSuccessPrecompile();

        vm.prank(owner);
        judge.judgeAll(bountyId, "input");

        vm.prank(owner);
        vm.expectRevert(bytes("already judged"));
        judge.judgeAll(bountyId, "input");
    }

    // ------------------------------------------------------------------
    // Finalization rules
    // ------------------------------------------------------------------

    function test_RevertWhen_FinalizeBeforeJudged() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "ans", salt);
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_FinalizeByNonOwner() public {
        uint256 bountyId = _fullyJudgedBounty();

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_FinalizeTwice() public {
        uint256 bountyId = _fullyJudgedBounty();

        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);

        vm.prank(owner);
        vm.expectRevert(bytes("already finalized"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_FinalizeInvalidWinnerIndex() public {
        uint256 bountyId = _fullyJudgedBounty();

        vm.prank(owner);
        vm.expectRevert(bytes("invalid winner index"));
        judge.finalizeWinner(bountyId, 5);
    }

    function _fullyJudgedBounty() internal returns (uint256 bountyId) {
        bountyId = _createBounty();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("ans", salt, alice, bountyId));
        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "ans", salt);
        vm.warp(revealDeadline + 1);

        _etchSuccessPrecompile();

        vm.prank(owner);
        judge.judgeAll(bountyId, "input");
    }
}
