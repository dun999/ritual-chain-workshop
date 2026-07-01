# Ritual Chain Workshop — AI Bounty Judge (Commit-Reveal Homework)

Fork of [cozfuttu/ritual-chain-workshop](https://github.com/cozfuttu/ritual-chain-workshop),
extended for the **Privacy-Preserving AI Bounty Judge** homework (see
[`docs/Ritual_AI_Bounty_Judge_Homework.pdf`](docs/Ritual_AI_Bounty_Judge_Homework.pdf)).

```
/hardhat -> Smart contract (AIJudge.sol), Solidity tests, deployment
/web     -> Next.js frontend
/docs    -> Homework deliverables (this README, architecture note, advanced-track design, reflection)
```

## The Problem

In the original workshop contract, `submitAnswer(bountyId, answer)` wrote the plaintext answer
to a public `Submission[]` array immediately. Anyone watching the chain (including other
participants) could read every earlier answer before the deadline and submit a copy or an
improved version. In a bounty where only one submission wins, that's a real fairness bug, not
just a privacy nicety.

## The Fix: Commit-Reveal

`AIJudge.sol` now splits submission into two phases:

1. **Commit** (`submitCommitment`) — before `submissionDeadline`, each participant submits only
   `commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`. The chain only
   ever sees a hash; the real answer isn't derivable from it.
2. **Reveal** (`revealAnswer`) — after `submissionDeadline` and before `revealDeadline`, each
   participant reveals `(answer, salt)`. The contract recomputes the hash and only accepts the
   reveal — and only then appends it to the (now genuinely public) `submissions` array — if it
   matches their original commitment. Binding `msg.sender` and `bountyId` into the hash means
   nobody can copy another participant's commitment and reveal it under their own address (see
   `test_RevertWhen_CopyCatCannotStealCommitment` in the test suite).
3. **Judge** (`judgeAll`) — after `revealDeadline`, the bounty owner triggers batch judging. This
   part didn't need to change: the workshop's contract already calls Ritual's LLM inference
   precompile (`0x0802`, via `PrecompileConsumer._executePrecompile`) **synchronously**, in one
   call, over every revealed submission. Because unrevealed commitments never entered the
   `submissions` array, they're automatically excluded from judging — there's nothing extra to
   filter.
4. **Finalize** (`finalizeWinner`) — the AI's raw output is stored on-chain as `bounty.aiReview`
   bytes (unparsed). A human (the bounty owner) reads it off-chain, picks a `winnerIndex`, and
   calls `finalizeWinner`, which validates the index against the revealed-submissions array and
   pays out. This was already the workshop's human-in-the-loop design — the homework's "AI
   recommends, human decides" requirement was already satisfied here, we just made sure an
   unrevealed submission can never be that index.

## What Changed in `AIJudge.sol`

- `Bounty.deadline` → `submissionDeadline` + `revealDeadline`.
- New `Commitment { bytes32 hash; bool revealed; }`, keyed by `(bountyId, participant)`.
- `submitAnswer` replaced by `submitCommitment` + `revealAnswer`. `submissions[]` now only ever
  contains **revealed** answers, appended in reveal order — `winnerIndex` / `getSubmission(index)`
  keep the exact same meaning they had before.
- Deadline enforcement is now real: the original `submitAnswer` had its deadline check commented
  out (`// require(block.timestamp < bounty.deadline, ...)`, left disabled for workshop-demo
  flexibility). Enforcing `submissionDeadline`/`revealDeadline` on both `submitCommitment` and
  `revealAnswer` is required by the homework and is no longer optional here.
- `finalizeWinner` now explicitly requires `winnerIndex < submissions.length` (previously an
  out-of-bounds index would just panic with an unhelpful array-access error).
- `getBounty` returns the new deadline fields plus `commitmentCount` (participants who committed,
  vs. `submissionCount`, participants who actually revealed).
- New `getCommitment(bountyId, participant)` and `computeCommitment(...)` (matches the on-chain
  hash formula, for clients/tests).

Full function reference: [`hardhat/contracts/AIJudge.sol`](hardhat/contracts/AIJudge.sol).

## Deployment

Deployed to the **Ritual chain** (chain id `1979`, `https://rpc.ritualfoundation.org`):

| | |
|---|---|
| Contract address | [`0xE83982a73D082F92B2f4760c7181639a64a90999`](https://explorer.ritualfoundation.org/address/0xE83982a73D082F92B2f4760c7181639a64a90999) |
| Deployment tx hash | [`0xd5994c1275c2db8c805839d4b99ce059902831e242886c391352015c8305a68b`](https://explorer.ritualfoundation.org/tx/0xd5994c1275c2db8c805839d4b99ce059902831e242886c391352015c8305a68b) |
| Block | `40213487` |
| Deployer | `0xC1d3366B1Ed25E127A25bBACAC50F2b1E4Fb624b` |

An earlier deployment at `0x36E39356CE13bd2d3981A6d2bB1A06E3c13EC8ad` (tx
`0xcfd4fa8a70bc9c9c0affb5bffe83d0f9d92525896ec58dac6363f412f1690246`) still has live, correct
bytecode, but that transaction later became unretrievable via `eth_getTransactionReceipt` /
`eth_getTransactionByHash` (the block it was recorded in returned different, empty contents on
re-query) — consistent with a reorg or receipt-history pruning on this chain rather than a failed
deploy. The table above reflects the redeploy done to get a currently-verifiable tx hash.

Deployed with `forge create` (Hardhat Ignition's interactive deploy UI didn't cooperate in a
non-TTY environment; `forge create` compiles `AIJudge.sol` with the same solc version/`viaIR`
setting as `hardhat.config.ts` and deploys directly):

```bash
forge create contracts/AIJudge.sol:AIJudge \
  --rpc-url https://rpc.ritualfoundation.org \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

(`AIJudge` has no constructor arguments — unlike the required-track homework spec's optional
oracle pattern, this contract doesn't need one: judging happens synchronously inside `judgeAll`
via the Ritual precompile, so there's no separate oracle address to configure.)

## Running Tests

```bash
cd hardhat
npm install
npx hardhat build
npx hardhat test solidity
```

23 Solidity tests in [`hardhat/contracts/AIJudge.t.sol`](hardhat/contracts/AIJudge.t.sol) cover
the full commit-reveal lifecycle, including a full end-to-end `judgeAll` → `finalizeWinner` run
against a **mocked LLM precompile** (`vm.etch` at `0x0802`), since the real precompile only exists
on Ritual chain itself. See the test file header for how the mock reproduces the precompile's
wire format.

## What Wasn't Updated

The `web/` frontend (`CreateBountyForm`, `SubmitAnswer`, etc.) still targets the old single-
`deadline`/`submitAnswer` ABI. `web/src/abi/AIJudge.ts` has been regenerated to match the new
contract, but the UI components have not been rewritten to add a commit step, a reveal step, or
a submission-hidden state — that's real frontend work (new forms, local storage for
answer+salt between commit and reveal, etc.) that's out of scope for "keep the required track
simple." The contract, tests, and docs are the graded deliverables per the homework and are
complete; the frontend is flagged here rather than silently left broken.

## Further Reading

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — commit-reveal vs. Ritual-native encrypted submissions.
- [`docs/advanced-track-ritual-native.md`](docs/advanced-track-ritual-native.md) — advanced-track
  design doc with a sequence diagram.
- [`REFLECTION.md`](REFLECTION.md) — the homework's reflection question.
