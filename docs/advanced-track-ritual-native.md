# Advanced Track (Design Document): Ritual-Native Hidden Submissions

This is a design, not shipped code (per the homework's note: "the advanced track can be a design
document if full implementation is too complex"). It describes how to close the one gap the
required commit-reveal track leaves open (see [`ARCHITECTURE.md`](../ARCHITECTURE.md)): in
commit-reveal, answers become plaintext on-chain the moment they're revealed, which happens
*before* `judgeAll` runs. Here, answers stay encrypted end-to-end and are decrypted only inside a
Ritual TEE, as part of the same call that judges them.

## Grounding this in what's already in the codebase

[`hardhat/contracts/utils/PrecompileConsumer.sol`](../hardhat/contracts/utils/PrecompileConsumer.sol)
already declares more precompiles than `AIJudge.sol` currently uses:

- `LLM_INFERENCE_PRECOMPILE` (`0x0802`) — what `judgeAll` already calls. Per the comment in
  `web/src/lib/ritualLlm.ts`, calling it triggers the block builder to run the model **inside a
  TEE executor** and replay the transaction with the signed result. So batch judging is *already*
  TEE-backed in this repo, today, in the required track.
- `DKMS_PRECOMPILE` (`0x081B`) — a "short-running async precompile," same category as
  `LLM_INFERENCE_PRECOMPILE`. This is Ritual's decentralized key management precompile: it's the
  natural mechanism for participants to encrypt an answer for a Ritual TEE's key, and for that
  same TEE to decrypt it later without the key ever existing outside enclave memory.
- `HTTP_CALL_PRECOMPILE` (`0x0801`) — usable for the TEE executor to fetch off-chain ciphertext
  blobs (e.g. from IPFS) if answers are too large to store as on-chain bytes.

None of these precompiles' exact request/response ABIs are publicly pinned down yet — the same
caveat already flagged in this repo's `web/src/lib/ritualLlm.ts` (`⚠️ TODO(ritual-abi)`) applies
here too. The design below is therefore expressed in terms of what each step needs to accomplish,
not exact calldata layouts.

## Flow Diagram

```mermaid
sequenceDiagram
    participant P as Participant
    participant C as AIJudge Contract
    participant D as DKMS Precompile (0x081B)
    participant S as Off-chain storage (ciphertext, if large)
    participant B as Ritual Block Builder / TEE Executor
    participant L as LLM Precompile (0x0802)

    Note over P,D: Submission phase
    P->>D: fetch bounty's TEE encryption public key
    P->>P: encrypt answer client-side
    P->>S: (optional) store ciphertext, get storageRef
    P->>C: submitEncryptedAnswer(bountyId, ciphertext | storageRef, ciphertextHash)
    Note over C: On-chain: ciphertext/ref + hash only. No plaintext, ever.

    Note over C,B: After submission deadline, owner triggers judging
    C-->>B: judgeAll(bountyId, llmInput) calls LLM_INFERENCE_PRECOMPILE
    B->>S: fetch ciphertext refs (if off-chain)
    B->>D: decrypt each ciphertext INSIDE the enclave (key never leaves TEE)
    B->>L: single batch prompt: rubric + all decrypted answers
    L-->>B: ranking + winnerIndex + reasoning
    B-->>C: signed result replayed into judgeAll's execution
    C->>C: bounty.judged = true; bounty.aiReview = completionData

    Note over C: Human-in-the-loop, same as required track
    Owner->>C: finalizeWinner(bountyId, winnerIndex)
    C->>P: pay reward to winner
    Note over C: revealedAnswersRef + revealedAnswersHash published so the reveal is checkable after the fact
```

## Answering the Required Design Questions

**Where do plaintext answers exist, and who can read them?**
Only in two places: (1) transiently on the participant's own device before encryption, and (2)
transiently inside the TEE executor's enclave memory during the `judgeAll` call, where the DKMS
precompile decrypts it for exactly as long as the LLM needs it. No other participant, the bounty
owner, or a chain observer can ever read a plaintext answer — there is no reveal step that
publishes it, unlike commit-reveal.

**What is stored on-chain vs. off-chain?**
On-chain: a ciphertext (if small enough) or a `storageRef` + `ciphertextHash` (if large, per the
homework's suggested pattern — same as `revealedAnswersRef`/`revealedAnswersHash`), the `judgeAll`
request, and after judging, the raw `aiReview` bytes (already how `AIJudge.sol` stores the AI's
output today) plus a hash commitment to any published reveal bundle. Off-chain: large ciphertext
blobs during submission, and after judging, an optional plaintext reveal bundle (all answers +
ranking) published for post-hoc auditability, referenced by `revealedAnswersRef`.

**How does the LLM receive all submissions together?**
Same mechanism `AIJudge.sol` already uses: the TEE executor assembles one batch prompt (rubric +
every decrypted answer) and makes a single call through `LLM_INFERENCE_PRECOMPILE`. The only
change from the required track is *what* the executor has to do before building that prompt —
decrypt via DKMS instead of just reading already-public revealed strings from contract storage.

**How does the final reveal happen?**
After judging, the executor (or the bounty owner, using data now available since judging is done)
publishes a `revealedAnswersBundle` off-chain and records its hash on-chain — exactly the
`revealedAnswersRef` / `revealedAnswersHash` pattern the homework suggests. This is optional in
the sense that judging doesn't depend on it, but it's what lets participants and observers verify
after the fact that judging was fair, without ever exposing anything before judging finished.

**How does the contract verify or commits to the final revealed bundle?**
The contract never re-derives the bundle's contents (it doesn't have the plaintext) — it only
stores `revealedAnswersHash = keccak256(bundle)`, ideally alongside the TEE's attestation/signed
result that already comes back from the `LLM_INFERENCE_PRECOMPILE` call. Anyone can fetch the
published bundle and recompute the hash to confirm no tampering.

**Avoiding large plaintext on-chain:** identical to the required track's `aiReview` bytes storage
today, plus the homework's suggested ref+hash pattern for anything too large to justify as
calldata — ciphertexts and reveal bundles both go off-chain, with only a reference and a 32-byte
hash on-chain.

## Ritual Feature Usage

- **TEE-backed execution:** already true of `judgeAll` in this repo today (per the block-builder
  comment in `ritualLlm.ts`); the advanced track extends the same TEE boundary backward to cover
  decryption, not just inference.
- **Encrypted inputs/secrets:** `DKMS_PRECOMPILE` is the mechanism — answers are encrypted
  client-side before ever leaving the participant's machine and are decrypted only inside the
  same enclave that runs the LLM call.
- **Batch judging:** unchanged from the required track — one `judgeAll` call, one LLM request
  covering every submission, never one call per answer.
- **Human-in-the-loop finalization:** unchanged — `bounty.aiReview` is unparsed raw model output;
  the owner reads it and calls `finalizeWinner(bountyId, winnerIndex)` explicitly. The AI never
  moves funds.

## Why This Is a Design Doc, Not Code

Implementing this needs the real `DKMS_PRECOMPILE` request/response ABI, which — like the LLM
precompile's ABI — isn't pinned down in this repo yet (see the `TODO(ritual-abi)` in
`web/src/lib/ritualLlm.ts`). Without it, any `submitEncryptedAnswer` implementation would be
guessing at an encoding the way `ritualLlm.ts` currently guesses at the LLM request layout. The
required-track contract already demonstrates the on-chain shape this would take (a request-style
call gated by deadlines and ownership, with the real work happening inside a TEE-backed
precompile), so wiring in `DKMS_PRECOMPILE` once its ABI is published is a natural extension of
`submitCommitment`, not a rewrite of the contract's structure.
