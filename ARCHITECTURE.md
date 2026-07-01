# Architecture Note: Commit-Reveal vs. Ritual-Native Encrypted Submissions

Both tracks solve the same problem — **stop later participants from reading earlier answers
before judging** — but they push the trust boundary to different places. Note that in this repo,
*both* tracks already rely on one Ritual-specific piece: `judgeAll` calls Ritual's LLM inference
precompile (`0x0802`) synchronously via `PrecompileConsumer._executePrecompile`, so batch judging
itself is Ritual-native regardless of which track is used for hiding submissions. The comparison
below is specifically about the **submission-hiding mechanism**.

## Commit-Reveal (implemented, required track)

- **Hiding mechanism:** a one-way hash (`keccak256`). No party — not other participants, not the
  bounty owner, not the chain itself — can invert a commitment back to the plaintext answer
  before the participant chooses to reveal it. This requires no special infrastructure and works
  on any EVM chain, which is exactly why it's the required track.
- **When answers become public:** the moment each participant calls `revealAnswer`, which by
  construction happens *before* `judgeAll` (`revealDeadline` gates both). So every revealed answer
  is sitting in public contract storage, readable by anyone, before the AI ever looks at it. The
  AI is judging data that's already public at judging time.
- **What's on-chain:** commitment hashes during submission; full plaintext answers (as `string`,
  in `bounty.submissions`) from reveal onward; the raw AI output bytes (`bounty.aiReview`).
- **The gap this leaves:** this is exactly what the homework calls out — commit-reveal only
  protects the *submission* window. It does not protect the window between reveal and judging,
  because on a public chain "revealed" and "public" are the same event.

## Ritual-Native Encrypted Submissions (advanced track — see [`docs/advanced-track-ritual-native.md`](docs/advanced-track-ritual-native.md))

- **Hiding mechanism:** encryption for a Ritual TEE, plus attestation. Participants trust that
  the enclave running the judging workload is the code it claims to be (verified via remote
  attestation), not that a hash is one-way. Decryption keys are only ever unwrapped inside the
  enclave.
- **When answers become public:** never, until the enclave explicitly publishes a reveal bundle
  *after* judging finishes. This closes the gap commit-reveal leaves open — nobody can read a
  plaintext answer before it's been judged, full stop.
- **What's on-chain:** only encrypted blobs (or references/hashes to them) during submission, and
  after judging, a reference + hash to the off-chain reveal bundle. Plaintext never touches
  contract storage at any point.
- **Cost/complexity:** requires a real TEE executor and encrypted-storage pipeline beyond the
  `judgeAll` precompile call the required track already uses, plus trust in Ritual's attestation.

## Comparison

| | Commit-Reveal | Ritual-Native (TEE) |
|---|---|---|
| Hides answers from other participants during submission | Yes | Yes |
| Hides answers from *everyone* until judging is actually done | No — public at reveal, before judging | Yes — stays encrypted until after judging |
| Needs off-chain trusted infrastructure beyond the LLM precompile | No | Yes (TEE executor, attestation, encrypted storage) |
| Works on any EVM chain | Yes (the hiding mechanism; `judgeAll` itself is already Ritual-specific here) | No — requires Ritual (or an equivalent confidential-compute network) |
| Where plaintext ever exists outside the enclave/contract | On every revealer's client, then on-chain from reveal onward | Only on the participant's own client before encryption |
| Failure mode if the mechanism is unavailable | Reveal simply doesn't happen; funds are safe, answers stay hidden (but bounty is stuck) | Judging can't run; funds are safe but bounty can't resolve until the TEE service is back |

**Bottom line:** commit-reveal is the right default — cheap, auditable, and it already solves the
"copy an earlier answer" problem the homework opens with. But it does not fully solve "answers
stay hidden until judging is complete," because reveal necessarily happens before `judgeAll` and
reveal *is* publication. The Ritual-native TEE design is the strictly stronger guarantee — nothing
is ever public before an AI has judged it — at the cost of real infrastructure dependencies this
repo's `judgeAll` doesn't otherwise need.
