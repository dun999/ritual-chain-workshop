# Reflection

**What should be public, what should stay hidden, and what should be decided by AI versus by a
human in a bounty system?**

Bounty metadata should be public from the start — the reward, the rubric, the deadlines, how
many people have committed — because that's what lets everyone verify the process was run fairly
without exposing anyone's actual work. The answer content itself is the opposite: it should stay
hidden for as long as it can create an unfair advantage, which in a plain commit-reveal design
means from submission through the reveal deadline, but ideally — as the advanced track shows —
it should stay hidden all the way through judging itself, since commit-reveal still exposes
answers the moment they're revealed, before an AI has scored anything. Once judging is done,
answers and the reasoning behind the outcome should become public again; participants who didn't
win deserve to see why, and that transparency is what keeps the bounty owner honest. Judging —
reading and scoring several submissions against a rubric — is exactly the kind of repetitive,
comparative task an AI is well suited to, and this codebase's `judgeAll` already enforces the
right shape for that: one batch call over every revealed answer, not one call per submission,
so every entry is judged under identical context. But payout is irreversible, so a human has to
hold the final action: `AIJudge.sol` stores the AI's raw output as opaque bytes and requires the
bounty owner to separately call `finalizeWinner(bountyId, winnerIndex)` with an index the contract
validates against the actual revealed submissions — the AI never moves funds, and it can't cause
a payout to someone who never revealed a valid answer regardless of what it recommends. In short:
process and outcome are public, content is hidden until it can no longer be exploited, the AI
ranks, and a human pays.
