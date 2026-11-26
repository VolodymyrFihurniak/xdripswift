# Development notes for new sessions

Practical knowledge from earlier cloud sessions: how to verify work without a Swift compiler, the
mistakes that broke the CI build, and how the owner likes work delivered. `CLAUDE.md` holds the
architecture; this file holds the workflow.

## Working with the owner

- The owner writes in Ukrainian; answer in Ukrainian. Code, comments, commit messages and docs stay
  in English. Every user-facing string still needs its Ukrainian translation (see `CLAUDE.md`).
- Do not open a pull request unless asked. When the owner asks for one, a chain of stacked branches
  goes out as one PR from the last branch (it carries every commit).
- After the owner has merged a PR and reports a failing build, fix it **directly on `master`** (the
  owner asked for this explicitly). New features still go on a new branch from `master`.
- Builds run only when the owner starts the workflow (`.github/workflows/build_xdrip.yml`,
  `workflow_dispatch`). The owner pastes the failed job URL; read it with the GitHub MCP
  `get_job_logs` tool. Logs are large: save them and grep for `error:` (see below).
- Codex reviews every PR automatically. Read the threads with `pull_request_read`
  (`get_review_comments`), fix what is right, reply in the thread (with the Claude Code footer) and
  resolve it.

## Verifying without Xcode

Nothing Swift compiles in a cloud session. Before every commit run:

```sh
python3 tools/check_swift.py            # changed .swift files vs origin/master: new parse errors + CI pitfalls
python3 tools/check_strings.py          # every en/uk .strings table: parse errors, en/uk format mismatch
python3 tools/check_strings.py --missing  # also keys translated only in English
```

`check_swift.py` installs tree-sitter into `tools/.tslib` on first run (pip, git-ignored). It is
a parser, not a compiler: it catches unbalanced braces, broken syntax and the known pitfalls
below, never type errors. Read the code you call (signatures, optionality, access level) instead
of guessing, because the CI is the first compiler that sees it.

Numeric test expectations must come from a real computation, never from reasoning:

- logic ported from JugglucoNG Kotlin: run the Kotlin original on the JVM (below) and copy its
  output; that is how the Balanced/Responsive vectors were made;
- other arithmetic: a small Python port (use `numpy.float32` when the Swift code uses `Float`,
  results then match bit for bit); keep the expected values in the test with a comment saying
  where they came from.

### Kotlin core on the JVM

```sh
cp -r Sibionics2Core "$SCRATCH/core"
# in $SCRATCH/core/build.gradle.kts: jvmToolchain(21) and the fixtures srcDir as an absolute path
#   getByName("jvmTest").resources.srcDir(file("/home/user/xdripswift/xDrip Tests/Fixtures"))
cd "$SCRATCH/core" && gradle -q cleanJvmTest jvmTest
grep -l '<failure' build/test-results/jvmTest/*.xml   # gradle -q hides which test failed
```

Maven Central may answer 429 at first: retry. The Kotlin/Native (iOS) targets cannot be built
here. To get vectors from JugglucoNG code, put the unchanged Kotlin file in a scratch `jvmTest`
source set and `println` from a test (`gradle jvmTest -i | grep YOUR_TAG`).

## Mistakes that broke the CI build

Each of these passed every local check and failed on macOS. `check_swift.py` detects the first three.

| Mistake | Fix |
|---|---|
| `super.method()` inside an escaping closure (`{ [self] in ... }`): "using 'super' in a closure where 'self' is explicitly captured is not yet supported" | call `super` from a small private method and call that from the closure |
| `%` on a `Double`, e.g. `Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000 % 86_400)` ("'%' is unavailable") | precompute the literal, or `truncatingRemainder(dividingBy:)` |
| `data.append(flag ? 1 : 0)` or `data.append(1)` on a `Data`: compiles, but the untyped literal picks `Data.append<Int>` and writes **eight** bytes, so a binary snapshot no longer reads back (failed tests, not the build) | `data.append(UInt8(...))` |
| `UNUserNotificationCenter.add(request)` without `withCompletionHandler:` in a context that is not async | `add(request, withCompletionHandler: nil)` |
| `@State` declared in a struct other than the view that uses it | keep `@State` in the `View` whose `body` reads it |
| a long `[...] + [...] + [...]` chain of array literals in a test ("unable to type-check in reasonable time") | build the array with a helper or `append(contentsOf:)` |
| `Math.PI` in Kotlin common code | `kotlin.math.PI` (no `java.*` in `commonMain`; `java.io` streams likewise, see `V115GSnapshotIO.kt`) |
| merging `upstream/master` with conflicting `uk.lproj` tables | see "Upstream sync" in `CLAUDE.md` |

Also watch for: a new `case` in an enum that some `switch` elsewhere lists exhaustively (grep the
type name), `private` helpers used from another file, `MainActor`-isolated calls from a
`nonisolated` delegate method (wrap in `MainActor.assumeIsolated`), a new file not in
`project.pbxproj` (prefer extending an existing file).

### Reading a failed job

```sh
# get_job_logs(job_id, return_content: true, tail_lines: 4000) saves a large log to a file
python3 -c "import json,re,sys; t=open(sys.argv[1]).read();
t=json.loads(t).get('logs_content',t) if t.startswith('{') else t
print('\n'.join(sorted(set(l[29:] for l in re.findall(r'[^\n]*error:[^\n]*', t)))))" LOGFILE
```

Fix every distinct error in one commit; the compiler stops per file, so also grep your other
changed files for the same pattern before pushing.

## JugglucoNG as the reference

```sh
git clone --filter=blob:none https://github.com/ctqvva/JugglucoNG.git "$SCRATCH/ref/JugglucoNG"
cd "$SCRATCH/ref/JugglucoNG"
git show origin/HEAD:Common/src/main/java/tk/glucodata/drivers/sibionics/SibionicsAlgorithm.kt
git log origin/HEAD --oneline -i --grep='keyword'
git ls-tree -r --name-only origin/HEAD -- Common/src/main/java/tk/glucodata | grep -i keyword
```

`git grep` over the whole tree and an unscoped `git ls-tree -r -l` can hang for minutes on the
partial clone: always pass a path and a `timeout`. JugglucoNG's own unit tests
(`Common/src/testMobile/...`, `Common/src/test/...`) are the best source of test cases to port.
Port behaviour faithfully and say so in a doc comment (`JugglucoNG <ClassName>`); where iOS cannot
do the same (background NFC, Bluetooth MAC address), document the difference.

## Where things stand

The ported features and their files are listed in `CLAUDE.md`. Everything there was written
without a device: none of it has been tried on a real sensor, meter or pen. Worth checking on
hardware first, roughly in order of risk:

1. Sibionics source journal and local recalculation (`replayFromJournal`): changing the glucose
   model on a running sensor should recalculate quickly and keep receiving new minutes.
2. Sibionics 2 reset reminder notification and its two actions, including with the app in the
   background.
3. Bluetooth glucose meters (Glucose Profile, Verio, Satellite): pairing prompt, record cursor.
4. Libre 2 stream watchdog: a hung link is dropped after 150 s and comes back 5 s later.
5. Alarm quiet window: sound held back, lows still breaking through.

Not portable to iOS: NovoPen unattended background reading (NFC needs a user tap).
