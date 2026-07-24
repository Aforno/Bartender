let meta = #{
    name: "audit-and-fix",
    description: "Build/test Bar Tender, audit the whole app for bugs, verify findings, fix confirmed issues, re-verify",
    when_to_use: "Full app health check: compile, tests, multi-area code audit, fix real bugs",
    phases: [
        #{ title: "Baseline", detail: "swift build + swift test" },
        #{ title: "Audit", detail: "parallel area reviews across the app" },
        #{ title: "Verify", detail: "adversarial check of each finding" },
        #{ title: "Fix", detail: "apply fixes for confirmed bugs" },
        #{ title: "Confirm", detail: "rebuild, retest, report" },
    ],
};

let findings_schema = #{
    "type": "object",
    "required": ["findings"],
    "properties": #{
        "findings": #{
            "type": "array",
            "maxItems": 6,
            "items": #{
                "type": "object",
                "required": ["file", "line", "severity", "issue", "repro"],
                "properties": #{
                    "file": #{ "type": "string" },
                    "line": #{ "type": "integer" },
                    "severity": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "repro": #{ "type": "string" },
                },
            },
        },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["real", "reason", "evidence"],
    "properties": #{
        "real": #{ "type": "boolean" },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let fix_schema = #{
    "type": "object",
    "required": ["fixed", "skipped", "summary", "files_changed"],
    "properties": #{
        "fixed": #{
            "type": "array",
            "items": #{
                "type": "object",
                "required": ["file", "issue", "what_changed"],
                "properties": #{
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "what_changed": #{ "type": "string" },
                },
            },
        },
        "skipped": #{
            "type": "array",
            "items": #{
                "type": "object",
                "required": ["file", "issue", "why"],
                "properties": #{
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "why": #{ "type": "string" },
                },
            },
        },
        "summary": #{ "type": "string" },
        "files_changed": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let confirm_schema = #{
    "type": "object",
    "required": ["build_ok", "tests_ok", "notes", "remaining_risks"],
    "properties": #{
        "build_ok": #{ "type": "boolean" },
        "tests_ok": #{ "type": "boolean" },
        "notes": #{ "type": "string" },
        "remaining_risks": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

// ---------- Phase 1: Baseline build + tests ----------
phase("Baseline");
log("Running swift build and swift test as baseline");

let baseline_prompt = "";
baseline_prompt += "You are verifying the Bar Tender (BarTender) macOS SwiftUI/menu-bar app at the workspace root.\n";
baseline_prompt += "Do ALL of the following with shell tools:\n";
baseline_prompt += "1. Run `swift build` from the repo root. Capture full failure output if it fails.\n";
baseline_prompt += "2. Run `swift test` from the repo root. Capture failing test names and messages.\n";
baseline_prompt += "3. Note platform requirements (macOS 26+) if build fails for that reason.\n";
baseline_prompt += "Return a structured object. Put build/test log excerpts in notes. List any compile or test failures as remaining_risks entries.\n";
baseline_prompt += "Set build_ok/tests_ok strictly from the command exit codes.\n";

let baseline = agent(baseline_prompt, #{
    label: "baseline-build-test",
    capability_mode: "all",
    output_schema: confirm_schema,
});

let baseline_build_ok = false;
let baseline_tests_ok = false;
let baseline_notes = "Baseline agent failed";
if baseline != () && baseline.success && baseline.output != () {
    baseline_build_ok = baseline.output.build_ok == true;
    baseline_tests_ok = baseline.output.tests_ok == true;
    if baseline.output.notes != () {
        baseline_notes = baseline.output.notes;
    }
}
log("Baseline: build_ok=" + baseline_build_ok.to_string() + " tests_ok=" + baseline_tests_ok.to_string());

// ---------- Phase 2: Parallel area audits ----------
phase("Audit");
log("Auditing Services, Stores, Views, App/Models, and Tests in parallel");

let common_audit = "";
common_audit += "You are auditing Bar Tender, a native macOS app (Swift / SwiftUI) that turns natural-language into live menu bar applets.\n";
common_audit += "It uses local AI CLIs (Codex/Claude/Grok), generates zsh tool artifacts, runs probes (HTTP/port/git/shell/metrics), and manages menu bar status items.\n";
common_audit += "Workspace root is the Bartender project. Use read_file, grep, list_dir only — no edits.\n";
common_audit += "Read real source before reporting. Do not invent issues from memory.\n";
common_audit += "Report ONLY real bugs / correctness defects / crashes / data loss / security holes / broken control flow.\n";
common_audit += "Do NOT report style nits, renames, or speculative refactors.\n";
common_audit += "severity must be one of: bug, security, crash, data-loss.\n";
common_audit += "Each finding needs file (repo-relative path), approximate line, clear issue, and repro or why it fails.\n";
common_audit += "Empty findings is valid ONLY after you have actually read the code in your area.\n";
common_audit += "Prefer at most 6 highest-confidence findings.\n";

let audit_jobs = [];

let p_services = common_audit;
p_services += "AREA: Services / runtime / probes / process execution.\n";
p_services += "Read and audit all files under Sources/BarTender/Services/.\n";
p_services += "Focus especially on: AppletRuntimeEngine, GeneratedToolService, ProcessRunner, ShellCommandProbe, ShellApprovalStore, ShellEnvironment, AIProviderService, UpdateService, StatusItemManager, and probe services (HTTP/Port/Git/Hardware/SystemMetrics).\n";
p_services += "Look for: shell injection, approval-bypass (fingerprint mismatch), race conditions on process lifecycle, unsafe PATH/env handling, generated-tool execution without approval, path traversal under Application Support, wrong status/health reporting, retain cycles, missing cancellation, update download/install flaws.\n";
audit_jobs.push(#{
    prompt: p_services,
    label: "audit:services",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let p_stores = common_audit;
p_stores += "AREA: Stores / persistence / app model.\n";
p_stores += "Read and audit all files under Sources/BarTender/Stores/ (AppletStore, AppModel, AppPreferences).\n";
p_stores += "Look for: data loss on save/load, corrupt manifests, race conditions on concurrent store updates, wrong encoding/decoding, preference defaults that break security (auto-approve edge cases), identity/id collisions, incomplete delete of generated tools or status items.\n";
audit_jobs.push(#{
    prompt: p_stores,
    label: "audit:stores",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let p_views = common_audit;
p_views += "AREA: SwiftUI views / menu bar UI.\n";
p_views += "Read and audit all files under Sources/BarTender/Views/ and Sources/BarTender/Support/.\n";
p_views += "Look for: thread-unsafe UI updates, force-unwrap crashes, broken composer/edit flows, trust disclosure bypasses, settings that do not persist, menu bar panel lifecycle bugs, wrong provider/model selection state, keyboard shortcut conflicts, missing error surfaces.\n";
audit_jobs.push(#{
    prompt: p_views,
    label: "audit:views",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let p_app = common_audit;
p_app += "AREA: App shell / models / manifests.\n";
p_app += "Read Sources/BarTender/App/, Sources/BarTender/Models/, Sources/BarTender/Resources/applet-manifest.schema.json, Package.swift, and packaging scripts under script/ if relevant.\n";
p_app += "Look for: lifecycle bugs (menu bar extra + main window), LaunchAtLogin issues, manifest schema vs decoder mismatches, AppletKind/runtime state machine holes, model catalog inconsistencies, resource loading failures.\n";
audit_jobs.push(#{
    prompt: p_app,
    label: "audit:app-models",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let p_tests = common_audit;
p_tests += "AREA: Tests and consistency.\n";
p_tests += "Read Tests/BarTenderTests/ and compare with Sources they cover. Prefer read-only inspection.\n";
p_tests += "Find: incorrect assertions, tests that pass while production code is wrong, missing coverage that hides security/approval bugs, flaky assumptions about PATH or environment, Packaging/script inconsistencies with Package.swift.\n";
audit_jobs.push(#{
    prompt: p_tests,
    label: "audit:tests",
    capability_mode: "read-only",
    output_schema: findings_schema,
});

let audit_results = parallel(audit_jobs);

let findings = [];
let seen = #{};
for r in audit_results {
    if r != () && r.success && r.output != () && r.output.findings != () {
        for f in r.output.findings {
            if f.file != () && f.issue != () {
                let key = f.file + "|" + f.issue;
                if !seen.contains(key) {
                    seen[key] = true;
                    findings.push(f);
                }
            }
        }
    }
}
log("Collected " + findings.len().to_string() + " unique audit findings before verification");

// If baseline failed, inject a high-priority finding so fix phase addresses it
if !baseline_build_ok || !baseline_tests_ok {
    findings.insert(0, #{
        file: "Package.swift",
        line: 1,
        severity: "bug",
        issue: "Baseline build or tests failed. build_ok=" + baseline_build_ok.to_string() + " tests_ok=" + baseline_tests_ok.to_string() + ". Notes: " + baseline_notes,
        repro: "swift build && swift test from repo root",
    });
}

if findings.len() == 0 {
    let empty_report = "";
    empty_report += "# Bar Tender audit-and-fix\n\n";
    empty_report += "Baseline build_ok=" + baseline_build_ok.to_string() + " tests_ok=" + baseline_tests_ok.to_string() + "\n\n";
    empty_report += baseline_notes + "\n\n";
    empty_report += "No audit findings after scanning Services, Stores, Views, App/Models, and Tests.\n";
    let path = write_scratch_file("audit-report.md", empty_report);
    complete(#{
        summary: "No findings; baseline ok=" + baseline_build_ok.to_string() + "/" + baseline_tests_ok.to_string(),
        confirmed: [],
        fixed: [],
        path: path,
    });
}

// Cap verification fan-out
let MAX_VERIFY = 10;
if findings.len() > MAX_VERIFY {
    log("Truncating findings from " + findings.len().to_string() + " to " + MAX_VERIFY.to_string() + " for verification budget");
    let trimmed = [];
    let i = 0;
    while i < MAX_VERIFY {
        trimmed.push(findings[i]);
        i += 1;
    }
    findings = trimmed;
}

// ---------- Phase 3: Adversarial verify ----------
phase("Verify");
log("Adversarially verifying " + findings.len().to_string() + " findings");

let vjobs = [];
for f in findings {
    let vp = "";
    vp += "You are an adversarial verifier for the Bar Tender Swift macOS codebase.\n";
    vp += "Independently inspect the code with read_file/grep. Do not trust the finding.\n";
    vp += "Finding file: " + f.file + "\n";
    if f.line != () {
        vp += "Claimed line: " + f.line.to_string() + "\n";
    }
    if f.severity != () {
        vp += "Claimed severity: " + f.severity + "\n";
    }
    vp += "Claimed issue: " + f.issue + "\n";
    if f.repro != () {
        vp += "Claimed repro: " + f.repro + "\n";
    }
    vp += "Set real=true ONLY if you read the code and confirm a genuine bug that can cause wrong behavior, crash, data loss, or security issue.\n";
    vp += "If it is style, speculation, already fixed, environment-only (missing SDK), or you cannot find evidence, set real=false.\n";
    vp += "For baseline compile failures: real=true only if the failure is a code defect fixable in this repo, not merely missing macOS 26 SDK on the agent host.\n";
    vp += "evidence must quote concrete code facts (function names, conditions, missing guards).\n";
    vjobs.push(#{
        prompt: vp,
        label: "verify",
        capability_mode: "read-only",
        output_schema: verdict_schema,
    });
}

let verdicts = parallel(vjobs);

let confirmed = [];
let i = 0;
for v in verdicts {
    if v != () && v.success && v.output != () && v.output.real == true {
        if v.output.evidence != () && v.output.evidence != "" {
            let item = findings[i];
            item["verify_reason"] = v.output.reason;
            item["verify_evidence"] = v.output.evidence;
            confirmed.push(item);
        }
    }
    i += 1;
}
log(confirmed.len().to_string() + "/" + findings.len().to_string() + " findings confirmed as real bugs");

if confirmed.len() == 0 {
    let none_report = "";
    none_report += "# Bar Tender audit-and-fix\n\n";
    none_report += "Baseline build_ok=" + baseline_build_ok.to_string() + " tests_ok=" + baseline_tests_ok.to_string() + "\n\n";
    none_report += "Auditors proposed " + findings.len().to_string() + " findings; none survived adversarial verification.\n";
    none_report += "\n## Baseline notes\n" + baseline_notes + "\n";
    let path = write_scratch_file("audit-report.md", none_report);
    complete(#{
        summary: "0 confirmed bugs after verification",
        proposed: findings.len(),
        confirmed: [],
        fixed: [],
        path: path,
    });
}

// ---------- Phase 4: Fix confirmed bugs ----------
phase("Fix");
log("Fixing " + confirmed.len().to_string() + " confirmed bugs in the main workspace");

let fix_prompt = "";
fix_prompt += "You are fixing confirmed bugs in the Bar Tender (BarTender) Swift/SwiftUI macOS project.\n";
fix_prompt += "Work in the main workspace (no worktree isolation). Use read_file, search_replace/write, and shell.\n";
fix_prompt += "Rules:\n";
fix_prompt += "- Fix only the confirmed bugs listed below. No drive-by refactors.\n";
fix_prompt += "- Keep changes minimal and correct. Match existing style.\n";
fix_prompt += "- If a finding is wrong on closer inspection, put it in skipped with why.\n";
fix_prompt += "- After edits, run `swift build` and `swift test`. Fix compile/test breakages you introduced.\n";
fix_prompt += "- Prefer pure Swift Package Manager; do not invent an Xcode project unless one exists.\n";
fix_prompt += "- Do not commit unless asked.\n";
fix_prompt += "\nConfirmed bugs (JSON):\n";
fix_prompt += json_encode(confirmed);
fix_prompt += "\n\nReturn fixed/skipped/summary/files_changed accurately based on what you actually changed.\n";

let fix_result = agent(fix_prompt, #{
    label: "fix-bugs",
    capability_mode: "all",
    output_schema: fix_schema,
});

let fixed = [];
let skipped = [];
let files_changed = [];
let fix_summary = "Fix agent did not complete";
if fix_result != () && fix_result.success && fix_result.output != () {
    if fix_result.output.fixed != () { fixed = fix_result.output.fixed; }
    if fix_result.output.skipped != () { skipped = fix_result.output.skipped; }
    if fix_result.output.files_changed != () { files_changed = fix_result.output.files_changed; }
    if fix_result.output.summary != () { fix_summary = fix_result.output.summary; }
}
log("Fix summary: " + fix_summary);

// ---------- Phase 5: Confirm ----------
phase("Confirm");
log("Re-running build and tests after fixes");

let confirm_prompt = "";
confirm_prompt += "Verify the Bar Tender project after bug fixes.\n";
confirm_prompt += "1. Run `swift build` and `swift test` from the repo root.\n";
confirm_prompt += "2. Run `git status --short` and `git diff --stat` to see what changed.\n";
confirm_prompt += "3. Spot-check that claimed fixed files look coherent (read key diffs).\n";
confirm_prompt += "Set build_ok and tests_ok from command exit codes. Put log excerpts and remaining concerns in notes/remaining_risks.\n";

let confirm = agent(confirm_prompt, #{
    label: "confirm-build-test",
    capability_mode: "all",
    output_schema: confirm_schema,
});

let final_build_ok = false;
let final_tests_ok = false;
let final_notes = "Confirm agent failed";
let remaining = [];
if confirm != () && confirm.success && confirm.output != () {
    final_build_ok = confirm.output.build_ok == true;
    final_tests_ok = confirm.output.tests_ok == true;
    if confirm.output.notes != () { final_notes = confirm.output.notes; }
    if confirm.output.remaining_risks != () { remaining = confirm.output.remaining_risks; }
}

let report = "";
report += "# Bar Tender audit-and-fix report\n\n";
report += "## Baseline\n";
report += "- build_ok: " + baseline_build_ok.to_string() + "\n";
report += "- tests_ok: " + baseline_tests_ok.to_string() + "\n";
report += "- notes: " + baseline_notes + "\n\n";
report += "## Audit\n";
report += "- proposed findings: " + findings.len().to_string() + "\n";
report += "- confirmed after verification: " + confirmed.len().to_string() + "\n\n";
report += "### Confirmed bugs\n";
for c in confirmed {
    report += "- **" + c.file;
    if c.line != () { report += ":" + c.line.to_string(); }
    report += "** — " + c.issue + "\n";
    if c.verify_evidence != () {
        report += "  - evidence: " + c.verify_evidence + "\n";
    }
}
report += "\n## Fixes\n";
report += fix_summary + "\n\n";
report += "### Fixed (" + fixed.len().to_string() + ")\n";
for f in fixed {
    report += "- " + f.file + ": " + f.issue + " → " + f.what_changed + "\n";
}
report += "\n### Skipped (" + skipped.len().to_string() + ")\n";
for s in skipped {
    report += "- " + s.file + ": " + s.issue + " (" + s.why + ")\n";
}
report += "\n### Files changed\n";
for p in files_changed {
    report += "- " + p + "\n";
}
report += "\n## Final verification\n";
report += "- build_ok: " + final_build_ok.to_string() + "\n";
report += "- tests_ok: " + final_tests_ok.to_string() + "\n";
report += "- notes: " + final_notes + "\n";
if remaining.len() > 0 {
    report += "\n### Remaining risks\n";
    for r in remaining {
        report += "- " + r + "\n";
    }
}

let report_path = write_scratch_file("audit-report.md", report);
log("Wrote audit report");

complete(#{
    summary: "Confirmed " + confirmed.len().to_string()
        + " bugs; fixed " + fixed.len().to_string()
        + "; final build=" + final_build_ok.to_string()
        + " tests=" + final_tests_ok.to_string(),
    confirmed_count: confirmed.len(),
    fixed_count: fixed.len(),
    skipped_count: skipped.len(),
    build_ok: final_build_ok,
    tests_ok: final_tests_ok,
    path: report_path,
});
