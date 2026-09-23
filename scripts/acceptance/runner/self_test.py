"""Runner self-tests: everything that does not need the app, proven.

Covers the fixture page's real behavior, probe argument plumbing, the evidence
schema, every scenario judge (including the ones whose app probe does not exist
yet), dry-run consistency and rerun hygiene, child-process discipline, and
secret hygiene. Every test asserts observable results, never internal mechanics.
A failure prints the raw evidence that disproved the expectation.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from . import conversation_driver, dry_run, evidence, orchestration, paths, run_mutex
from .app_identity import inspect_app_identity
from .fixture_page import FixtureError, FixtureServer
from .process_control import (
    OwnedProcessRegistry,
    OwnedProcess,
    port_accepts_connections,
    spawn_owned_process,
    terminate_owned_process,
)
from .probe_runner import (
    PREFLIGHT_FLAG,
    ProbeError,
    ProbeRequest,
    binary_supports_flag,
    build_probe_argv,
    run_preflight,
    run_probe,
)
from .scenario_judges import judge_scenario
from .scenarios import load_scenarios
from .synthetic_speech import (
    PCM_SAMPLE_RATE_HZ,
    SpeechSynthesisError,
    synthesize_placeholder_for_self_tests,
    synthesize_utterance,
    validate_raw_pcm,
)
from .orchestration import (
    RUN_MUTEX_BLOCKED_EXIT_CODE,
    SIGINT_EXIT_CODE,
    AbortState,
    RunContext,
    RunOptions,
    _abort_exit_code,
    _install_abort_signal_handlers,
    _preflight_gate,
    _restore_signal_handlers,
    run_acceptance,
)


class SelfTestFailure(AssertionError):
    pass


def _check(condition: bool, message: str) -> None:
    if not condition:
        raise SelfTestFailure(message)


def _scenario_by_name(name: str):
    matches = [scenario for scenario in load_scenarios() if scenario.name == name]
    if not matches:
        raise SelfTestFailure(f"Scenario {name!r} is not defined.")
    return matches[0]


# --------------------------------------------------------------- fixture page


def test_fixture_lifecycle_and_state_semantics(work_dir: Path) -> list[str]:
    registry = OwnedProcessRegistry()
    fixture = FixtureServer(work_dir / "fixture-semantics", registry)
    try:
        start = fixture.start()
        _check(isinstance(start.get("pid"), int), f"fixture did not start: {start}")
        fixture.assert_controlled_page_marker()
        state = fixture.reset()
        _check(state.get("selected") is None and state.get("clicks") == 0
               and state.get("events") == [] and state.get("menu_open") is False,
               f"/state not clean after reset: {state}")

        views_before = fixture.state().get("page_views")
        fixture.fetch_page()
        fixture.fetch_page()
        views_after = fixture.state().get("page_views")
        _check(views_after == (views_before or 0) + 2,
               f"page_views did not count page loads: {views_before} -> {views_after}")

        fixture.state()
        fixture.state()
        _check(fixture.state().get("page_views") == views_after,
               "page_views must not count /state reads")

        accepted = fixture._request("POST", "/select", {"selected": "right-setting"})
        _check(accepted.get("selected") == "right-setting" and accepted.get("clicks") == 1
               and accepted.get("events") == ["right-setting"],
               f"right-setting select failed: {accepted}")

        rejected_early = fixture._request("POST", "/select", {"selected": "scale"})
        _check(rejected_early.get("selected") == "right-setting" and rejected_early.get("clicks") == 1,
               f"scale must be rejected before the menu opens: {rejected_early}")

        menu = fixture._request("POST", "/menu", {})
        _check(menu.get("menu_open") is True and menu.get("events")[-1] == "open-menu",
               f"menu open failed: {menu}")
        scale = fixture._request("POST", "/select", {"selected": "scale"})
        _check(scale.get("selected") == "scale" and scale.get("clicks") == 2
               and scale.get("events") == ["right-setting", "open-menu", "scale"],
               f"scale select after menu failed: {scale}")

        left = fixture._request("POST", "/select", {"selected": "left-setting"})
        _check(left.get("selected") == "left-setting" and left.get("clicks") == 3,
               f"left-setting select failed: {left}")

        invalid = fixture._request("POST", "/select", {"selected": "not-a-control"})
        _check(invalid.get("selected") == "left-setting" and invalid.get("clicks") == 3,
               f"unknown control must not change state: {invalid}")

        reset_views = fixture.state().get("page_views")
        again = fixture.reset()
        _check(again.get("selected") is None and again.get("clicks") == 0
               and again.get("events") == [] and again.get("menu_open") is False,
               f"second reset failed: {again}")
        _check(again.get("page_views") == reset_views,
               "reset must not erase the page_views diagnostic")
        return [f"fixture pid {start['pid']} behaviors verified: reset, page_views, "
                f"select/menu ordering, rejection of scale before menu, invalid payload ignored"]
    finally:
        fixture.stop()


def test_fixture_port_release_and_second_start(work_dir: Path) -> list[str]:
    registry = OwnedProcessRegistry()
    first = FixtureServer(work_dir / "fixture-first-run", registry)
    second = FixtureServer(work_dir / "fixture-second-run", registry)
    try:
        first.start()
        first.stop()
        _check(not port_accepts_connections(paths.FIXTURE_HOST, paths.FIXTURE_PORT),
               "fixture port still occupied after stop: a rerun would be polluted")
        # The acceptance criterion requires the second run to start clean.
        start = second.start()
        _check(isinstance(start.get("pid"), int), "second fixture start failed")
        state = second.state()
        _check(state.get("clicks") == 0 and state.get("events") == [],
               f"second fixture run starts polluted: {state}")
        return [f"port {paths.FIXTURE_PORT} released and re-acquired by pid {start['pid']} "
                "with clean /state"]
    finally:
        first.stop()
        second.stop()


def test_fixture_refuses_occupied_port_without_killing(work_dir: Path) -> list[str]:
    blocking_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocking_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    blocking_socket.bind((paths.FIXTURE_HOST, paths.FIXTURE_PORT))
    blocking_socket.listen(1)
    registry = OwnedProcessRegistry()
    fixture = FixtureServer(work_dir / "fixture-occupied", registry)
    try:
        try:
            fixture.start()
        except FixtureError as error:
            _check("already occupied" in str(error),
                   f"unexpected message for occupied port: {error}")
        _check(not registry.running(), "runner spawned or kept a process it must not touch")
        _check(fixture.owned is None,
               "fixture claimed ownership of an unrelated listener")
        return ["occupied port refused without spawning or killing anything"]
    finally:
        blocking_socket.close()
        time.sleep(0.2)


# ------------------------------------------------------------ synthetic speech


def test_synthetic_pcm_pipeline(work_dir: Path) -> list[str]:
    cache_dir = work_dir / "utterances"
    text = "点击右边的设置按钮"
    audio = synthesize_utterance(text, cache_dir)
    _check(audio.is_real_speech is True, "system TTS output must be labeled real speech")
    _check(audio.byte_count > 0, "synthesized PCM is empty")
    validate_raw_pcm(audio.pcm_path.read_bytes())
    _check(abs(audio.duration_seconds - audio.byte_count / 2 / PCM_SAMPLE_RATE_HZ) < 1e-6,
           "duration metadata disagrees with byte count")
    cached = synthesize_utterance(text, cache_dir)
    _check(cached.cached is True and cached.pcm_path == audio.pcm_path,
           "second synthesis did not reuse the cache")
    _check(cached.byte_count == audio.byte_count, "cached audio differs in size")
    try:
        synthesize_utterance("   ", cache_dir)
    except SpeechSynthesisError:
        pass
    else:
        raise SelfTestFailure("empty utterance must be refused")
    placeholder = synthesize_placeholder_for_self_tests(text, cache_dir)
    _check(placeholder.is_real_speech is False,
           "placeholder audio must be labeled as not real speech")
    return [f"say+afconvert produced {audio.byte_count} bytes "
            f"({audio.duration_seconds:.2f}s, voice {audio.voice}); cache hit on resynthesis; "
            "placeholder labeled non-evidence"]


# ------------------------------------------------------------ probe plumbing


def test_probe_argument_plumbing() -> list[str]:
    binary = Path("/Applications/Her.app/Contents/MacOS/Her")
    pcm = Path("/tmp/utterance.pcm")
    out_dir = Path("/tmp/attempt-dir")

    argv = build_probe_argv(ProbeRequest(
        mode="voice_task", app_binary=binary, working_out_dir=out_dir,
        expected_bundle_identifier="com.apple.Safari", utterance_pcm_paths=[pcm]))
    _check(argv == [str(binary), "--voice-task-probe", "com.apple.Safari", str(pcm), str(out_dir)],
           f"voice_task argv wrong: {argv}")

    argv = build_probe_argv(ProbeRequest(
        mode="voice_continuity", app_binary=binary, working_out_dir=out_dir,
        utterance_pcm_paths=[pcm, Path("/tmp/cancel.pcm")],
        report_file_name="continuity-report.json"))
    _check(argv == [str(binary), "--voice-continuity-probe", str(pcm),
                    "/tmp/cancel.pcm", str(out_dir / "continuity-report.json")],
           f"voice_continuity argv wrong: {argv}")

    argv = build_probe_argv(ProbeRequest(
        mode="desktop_task", app_binary=binary, working_out_dir=out_dir,
        tool_arguments_json='{"goal":"x"}', report_file_name="task.json"))
    _check(argv == [str(binary), "--desktop-task-probe", "com.apple.Safari", '{"goal":"x"}',
                    str(out_dir / "task.json")],
           f"desktop_task argv wrong: {argv}")

    argv = build_probe_argv(ProbeRequest(
        mode="voice_route", app_binary=binary, working_out_dir=out_dir,
        utterance_pcm_paths=[pcm]))
    _check(argv == [str(binary), "--voice-route-probe", str(pcm), str(out_dir)],
           f"voice_route argv wrong: {argv}")

    argv = build_probe_argv(ProbeRequest(
        mode="jev_fanout", app_binary=binary, working_out_dir=out_dir,
        goal_text="点击检查官网部署状态（3）", report_file_name="fanout.json"))
    _check(argv == [str(binary), "--jev-fanout-probe", "com.apple.Safari",
                    "点击检查官网部署状态（3）", str(out_dir / "fanout.json")],
           f"jev_fanout argv wrong: {argv}")

    argv = build_probe_argv(ProbeRequest(
        mode="unknown", app_binary=binary, working_out_dir=out_dir,
        utterance_pcm_paths=[pcm],
        unknown_argv_template=["{app_binary}", "--unknown-delivery-probe",
                               "{bundle_id}", "{pcm}", "{report}"]))
    _check(argv == [str(binary), "--unknown-delivery-probe", "com.apple.Safari", str(pcm),
                    str(out_dir / "report.json")],
           f"unknown template substitution wrong: {argv}")

    for bad_mode, kwargs in (
        ("voice_task", dict(utterance_pcm_paths=[])),
        ("voice_continuity", dict(utterance_pcm_paths=[pcm])),
        ("desktop_task", dict()),
        ("voice_route", dict(utterance_pcm_paths=[pcm, pcm])),
        ("unknown", dict()),
    ):
        try:
            build_probe_argv(ProbeRequest(mode=bad_mode, app_binary=binary,
                                          working_out_dir=out_dir, **kwargs))
        except ProbeError:
            continue
        raise SelfTestFailure(f"{bad_mode} accepted invalid arguments: {kwargs}")
    return ["all five documented probe argvs and the unknown-template substitution are "
            "exact; malformed requests are refused"]


def test_binary_flag_detection(work_dir: Path) -> list[str]:
    binary_with_flag = work_dir / "binary-with-flag"
    binary_without_flag = work_dir / "binary-without-flag"
    binary_with_flag.write_bytes(b"\x00fake-macho" + b"--unknown-delivery-probe" + b"\x00rest")
    binary_without_flag.write_bytes(b"\x00fake-macho--voice-task-probe\x00rest")
    _check(binary_supports_flag(binary_with_flag, "--unknown-delivery-probe"),
           "flag present in binary was not detected")
    _check(not binary_supports_flag(binary_without_flag, "--unknown-delivery-probe"),
           "absent flag was reported as present")
    _check(not binary_supports_flag(work_dir / "missing", "--any"),
           "missing binary reported as supporting a flag")
    return ["Mach-O flag detection distinguishes present/absent/missing correctly"]


# ------------------------------------------------------------ evidence schema


def _valid_dry_run_result() -> dict:
    return {
        "schema_version": 1, "work_order": paths.WORK_ORDER_ID, "commit": "abc123",
        "branch": "test/her-e2e-runner", "app_bundle": "Her.app",
        "bundle_id": paths.EXPECTED_BUNDLE_IDENTIFIER, "team_id": paths.EXPECTED_TEAM_IDENTIFIER,
        "entrypoint": "python3 scripts/acceptance/her_voice_e2e.py --dry-run --out /tmp/x",
        "provider_connection_attempted": False, "synthetic_audio": True,
        "microphone_opened": False, "desktop_fixture_only": True, "mode": "dry_run",
        "proof": False, "started_at": "now", "finished_at": "later",
        "scenarios": [{
            "name": "single_step_right_setting", "title": "A", "status": "passed",
            "user_words": "点击右边的设置按钮", "model_tool_arguments": [],
            "task_turn_attempt_ids": {}, "her_receipt": {}, "independent_state": {},
            "final_speech": [], "failure_recovery": {}, "basis": ["chain agrees"],
            "failure_reasons": [], "attempts": [],
        }],
        "passed": True, "exit_code": 0, "blocked_reason": None,
    }


def test_evidence_schema_validation() -> list[str]:
    valid = _valid_dry_run_result()
    _check(evidence.validate_result_schema(valid) == [],
           f"valid document rejected: {evidence.validate_result_schema(valid)}")

    broken_documents: list[tuple[str, dict]] = []
    missing_key = dict(valid)
    missing_key.pop("scenarios")
    broken_documents.append(("missing scenarios", missing_key))

    pass_without_basis = json.loads(json.dumps(valid))
    pass_without_basis["scenarios"][0]["basis"] = []
    broken_documents.append(("pass without basis", pass_without_basis))

    fail_without_reason = json.loads(json.dumps(valid))
    fail_without_reason["scenarios"][0]["status"] = "failed"
    broken_documents.append(("fail without reason", fail_without_reason))

    dry_run_claiming_proof = json.loads(json.dumps(valid))
    dry_run_claiming_proof["proof"] = True
    broken_documents.append(("dry run claiming proof", dry_run_claiming_proof))

    unknown_mode = json.loads(json.dumps(valid))
    unknown_mode["mode"] = "surprise"
    broken_documents.append(("unknown mode", unknown_mode))

    for label, document in broken_documents:
        problems = evidence.validate_result_schema(document)
        _check(problems, f"{label} was accepted by the schema validator")
    return ["schema validator accepts the good document and rejects 5 broken shapes "
            "(missing key, basis-less pass, reason-less fail, dry-run-as-proof, bad mode)"]


def test_secret_scan_detects_canaries() -> list[str]:
    canaries = [
        "sk-AAAA1234BBBB5678CCCC",
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN RSA PRIVATE KEY-----",
        "\"api_key\": \"abcdefghijklmnopqrstuvwx\"",
    ]
    for canary in canaries:
        hits = evidence.scan_for_secret_patterns(f"prefix {canary} suffix")
        _check(hits, f"secret canary slipped through: {canary}")
    _check(evidence.scan_for_secret_patterns("clean text about clicks and settings") == [],
           "clean evidence text was flagged")
    return ["4 secret canary shapes are detected; clean evidence text is not flagged"]


# ------------------------------------------------------------------- judges


def _judge(scenario_name: str, probe_record: dict, report: dict | None,
           state_before: dict, state_after: dict, require_language: bool = False):
    scenario = _scenario_by_name(scenario_name)
    return judge_scenario(scenario, probe_record, report, state_before, state_after,
                          require_evidence_language=require_language)


def _self_exited_record() -> dict:
    return {"exit_record": {"pid": 4242, "self_exited": True, "returncode": 0,
                            "timed_out": False}}


def _chain(name: str, quality: str) -> dict:
    scenario = _scenario_by_name(name)
    chain = dry_run.load_dry_run_chain(scenario, quality)
    return chain


def test_judge_single_step_scenario(work_dir: Path) -> list[str]:
    good = _chain("single_step_right_setting", dry_run.GOOD_CHAIN_SUFFIX)
    verdict = _judge("single_step_right_setting", _self_exited_record(), good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed, f"good chain rejected: {verdict.failure_reasons}")
    _check(any("delivery-sufficient" in line or "system-verified" in line
               for line in verdict.basis),
           f"a passing A chain must name its corroborated completion basis: {verdict.basis}")

    # Work order 03R item 8: the same chain carrying an uncertain_effect receipt is
    # an honest, safe FAILED attempt - never scenario A's PASS.
    uncertain = json.loads(json.dumps(good.report))
    uncertain_receipt = json.loads(uncertain["tool_results"][0])
    uncertain_receipt["status"] = "uncertain_effect"
    uncertain_receipt["completed_step_count"] = 0
    uncertain_receipt["actions"] = ["click「设置」：结果未确认"]
    uncertain_receipt["detail"] = "操作结果未确认，已停止；页面变化不等于目标完成。"
    uncertain["tool_results"][0] = json.dumps(uncertain_receipt, ensure_ascii=False)
    uncertain["rendered_texts"] = ["已向「设置」发送操作，但目标结果还没有确认，已停下。"]
    verdict = _judge("single_step_right_setting", _self_exited_record(), uncertain,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           f"an uncertain_effect receipt was passed for scenario A: {verdict.basis}")
    _check(any("uncertain_effect" in reason for reason in verdict.failure_reasons),
           f"the refusal must name the uncertain receipt: {verdict.failure_reasons}")
    _check(any("recorded as a FAILED attempt, never as a PASS" in line
               for line in verdict.basis),
           f"the honest failure must carry its own basis: {verdict.basis}")

    # delivery=unknown is not a delivered click for this scenario either.
    unknown = json.loads(json.dumps(good.report))
    unknown_receipt = json.loads(unknown["tool_results"][0])
    unknown_receipt["current_actions"][0]["delivery"] = "unknown"
    unknown["tool_results"][0] = json.dumps(unknown_receipt, ensure_ascii=False)
    verdict = _judge("single_step_right_setting", _self_exited_record(), unknown,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           f"delivery=unknown was passed for scenario A: {verdict.failure_reasons}")

    bad = _chain("single_step_right_setting", "bad_double_click")
    verdict = _judge("single_step_right_setting", _self_exited_record(), bad.report,
                     bad.state_before, bad.state_after)
    _check(not verdict.passed and any("click" in reason for reason in verdict.failure_reasons),
           f"duplicate click not rejected: {verdict.failure_reasons}")

    # Independent /state contradicting a completed receipt: the click never landed.
    lying = json.loads(json.dumps(good.report))
    lying["tool_results"][0] = json.dumps({
        "goal": "点击右边的设置按钮", "status": "completed",
        "detail": "任务步骤均已结束；各步完成依据已记录在操作历史中。",
        "task_id": "t", "turn_id": "u", "current_actions": [{
            "id": "a1", "label": "设置", "action": "click", "delivery": "sent",
            "outcome_evidence": "not_observed", "completion_policy": "delivery_sufficient",
            "completion_basis": None, "decision_packet": {"where": {"region": "right"}}}],
    }, ensure_ascii=False)
    verdict = _judge("single_step_right_setting", _self_exited_record(), lying,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           "completed receipt with completion_basis=None was accepted")

    # A completed receipt whose speech claims verification it does not have.
    overclaiming = json.loads(json.dumps(good.report))
    overclaiming["rendered_texts"] = ["已完成并确认这 1 步操作。"]
    verdict = _judge("single_step_right_setting", _self_exited_record(), overclaiming,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "overclaiming speech on an uncertain receipt was accepted")

    # A timeout must never pass, whatever the report claims.
    verdict = _judge("single_step_right_setting",
                     {"pid": 1, "self_exited": False, "returncode": None, "timed_out": True},
                     good.report, good.state_before, good.state_after)
    _check(not verdict.passed, "a timed-out probe was accepted")

    # A missing report must fail closed.
    verdict = _judge("single_step_right_setting", _self_exited_record(), None,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "a missing report was accepted")

    # A right_click contract must be rejected even with perfect /state.
    right_click = json.loads(json.dumps(good.report))
    right_click["tool_results"][0] = right_click["tool_results"][0].replace('"action":"click"', '"action":"right_click"')
    verdict = _judge("single_step_right_setting", _self_exited_record(), right_click,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "right_click execution was accepted for a 右边 request")
    return ["scenario A: a completed receipt with delivery=sent and a corroborated "
            "completion basis passes; an uncertain_effect or delivery=unknown receipt, "
            "duplicate click, lying receipt, overclaiming speech, timeout, missing report "
            "and right_click are each rejected"]


def test_judge_two_step_scenario(work_dir: Path) -> list[str]:
    good = _chain("two_step_display_settings_scale", dry_run.GOOD_CHAIN_SUFFIX)
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed, f"good two-step chain rejected: {verdict.failure_reasons}")

    bad = _chain("two_step_display_settings_scale", "bad_open_app")
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), bad.report,
                     bad.state_before, bad.state_after)
    _check(not verdict.passed and any("open_app" in reason for reason in verdict.failure_reasons),
           f"the multi-step open_app bug signature was not rejected: {verdict.failure_reasons}")

    # Correct tool arguments but the page shows the wrong ordered side effects.
    wrong_order = json.loads(json.dumps(good.report))
    wrong_order["tool_results"][0] = wrong_order["tool_results"][0].replace(
        '"completed_step_count":2', '"completed_step_count":2')
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), wrong_order,
                     good.state_before,
                     {"selected": "scale", "clicks": 1, "menu_open": True,
                      "events": ["scale", "open-menu"], "page_views": 3})
    _check(not verdict.passed, "reordered page side effects were accepted")

    # A single top-level click is not the required two explicit steps.
    single_step = json.loads(json.dumps(good.report))
    single_step["calls"][0]["arguments"] = json.dumps(
        {"goal": "点击打开显示设置，然后点击缩放选项。", "action": "click",
         "target_label": "打开显示设置"}, ensure_ascii=False)
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), single_step,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "a single top-level click was accepted as the two-step scenario")

    # Work order 03R item 8: an uncertain receipt is this scenario's honest failure,
    # never its PASS, and every step must satisfy its own policy.
    uncertain = json.loads(json.dumps(good.report))
    uncertain_receipt = json.loads(uncertain["tool_results"][0])
    uncertain_receipt["status"] = "uncertain_effect"
    uncertain_receipt["completed_step_count"] = 0
    uncertain["tool_results"][0] = json.dumps(uncertain_receipt, ensure_ascii=False)
    uncertain["rendered_texts"] = ["已向「打开显示设置」发送操作，但结果还没有确认，已停下。"]
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), uncertain,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           f"an uncertain_effect receipt was passed for scenario C: {verdict.basis}")
    _check(any("uncertain_effect" in reason for reason in verdict.failure_reasons),
           f"the refusal must name the uncertain receipt: {verdict.failure_reasons}")

    # A step whose completion basis its policy does not license must fail the
    # scenario, even though both actions were delivered.
    unlicensed = json.loads(json.dumps(good.report))
    unlicensed_receipt = json.loads(unlicensed["tool_results"][0])
    unlicensed_receipt["current_actions"][1]["completion_basis"] = None
    unlicensed["tool_results"][0] = json.dumps(unlicensed_receipt, ensure_ascii=False)
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), unlicensed,
                     good.state_before, good.state_after)
    _check(not verdict.passed and any("corroborated" in reason
                                      for reason in verdict.failure_reasons),
           f"an unlicensed completion basis was accepted for scenario C: "
           f"{verdict.failure_reasons}")

    # A delivery=unknown step is not a delivered step for this scenario.
    unknown_delivery = json.loads(json.dumps(good.report))
    unknown_receipt_c = json.loads(unknown_delivery["tool_results"][0])
    unknown_receipt_c["current_actions"][0]["delivery"] = "unknown"
    unknown_delivery["tool_results"][0] = json.dumps(unknown_receipt_c, ensure_ascii=False)
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), unknown_delivery,
                     good.state_before, good.state_after)
    _check(not verdict.passed and any("delivery=unknown" in reason
                                      for reason in verdict.failure_reasons),
           f"delivery=unknown was accepted for scenario C: {verdict.failure_reasons}")

    # Overclaiming speech is refused on a completed receipt too.
    overclaiming = json.loads(json.dumps(good.report))
    overclaiming["rendered_texts"] = ["已完成并确认这 2 步操作。"]
    verdict = _judge("two_step_display_settings_scale", _self_exited_record(), overclaiming,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           f"overclaiming speech on a completed two-step receipt was accepted: "
           f"{verdict.basis}")

    return ["scenario C: two explicit steps, both delivered with delivery=sent and each "
            "step's policy-licensed completion basis, with exact ordered /state passes; "
            "the open_app bug signature, reordered side effects, a single-step submission, "
            "an uncertain receipt, an unlicensed basis, delivery=unknown and overclaiming "
            "speech are each rejected"]


def test_judge_continuity_scenario(work_dir: Path) -> list[str]:
    good = _chain("continuity_progress_cancel", dry_run.GOOD_CHAIN_SUFFIX)
    verdict = _judge("continuity_progress_cancel", _self_exited_record(), good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed, f"good continuity chain rejected: {verdict.failure_reasons}")

    bad = _chain("continuity_progress_cancel", "bad_reexecute")
    verdict = _judge("continuity_progress_cancel", _self_exited_record(), bad.report,
                     bad.state_before, bad.state_after)
    _check(not verdict.passed and any("progress" in reason for reason in verdict.failure_reasons),
           f"progress re-execution was not rejected: {verdict.failure_reasons}")

    # The reconnect must not lose the task identity.
    lost_task = json.loads(json.dumps(good.report))
    lost_task["rounds"][1]["task_id"] = "different-task-id"
    verdict = _judge("continuity_progress_cancel", _self_exited_record(), lost_task,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "a task identity change across reconnect was accepted")

    # The progress speech must not be shipped as verified when gated.
    mixed_language = json.loads(json.dumps(good.report))
    mixed_language["rounds"][0]["rendered_texts"] = ["任务尚未完成，已确认 1/2 步。"]
    advisory = _judge("continuity_progress_cancel", _self_exited_record(), mixed_language,
                      good.state_before, good.state_after, require_language=False)
    _check(advisory.passed and any("ADVISORY" in line for line in advisory.basis),
           "advisory language mode did not record the wording observation")
    gated = _judge("continuity_progress_cancel", _self_exited_record(), mixed_language,
                   good.state_before, good.state_after, require_language=True)
    _check(not gated.passed, "gated language mode accepted 已确认 wording for unverified steps")
    return ["scenario continuity: stable identity + fresh turn + zero re-execution passes; "
            "re-execution and lost identity are rejected; evidence-language gating works in "
            "both advisory and required modes"]


def test_judge_unknown_scenario(work_dir: Path) -> list[str]:
    good = _chain("unknown_delivery_fault_recovery", dry_run.GOOD_CHAIN_SUFFIX)
    verdict = _judge("unknown_delivery_fault_recovery", _self_exited_record(), good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed, f"good fault chain rejected: {verdict.failure_reasons}")

    bad = _chain("unknown_delivery_fault_recovery", "bad_reclick")
    verdict = _judge("unknown_delivery_fault_recovery", _self_exited_record(), bad.report,
                     bad.state_before, bad.state_after)
    _check(not verdict.passed and any("clicks" in reason for reason in verdict.failure_reasons),
           f"re-delivery of an unconfirmed attempt was not rejected: {verdict.failure_reasons}")

    # Fake certainty after the fault: the receipt claims sent, /state proves one click.
    fake_certain = json.loads(json.dumps(good.report))
    fake_certain["receipt"]["current_actions"][0]["delivery"] = "sent"
    verdict = _judge("unknown_delivery_fault_recovery", _self_exited_record(), fake_certain,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           "a receipt hiding the delivery-unknown state was accepted")
    return ["scenario unknown: delivery=unknown with one click and honest speech passes; "
            "re-click and a masked delivery state are rejected"]


def test_exit_status_honesty_for_launched_instances(work_dir: Path) -> list[str]:
    """The exit-code judgment: only a status the OS reported (or a documented
    derived value with its artifact behind it) may carry a verdict.

    A LaunchServices instance is not the runner's child, so the kernel reports it
    no exit status. `returncode: 0` therefore counts only together with a
    `returncode_basis` that starts with "derived:" and a present report artifact;
    a null returncode or an "unavailable" basis fails closed.
    """
    from . import launch_services

    good = _chain("single_step_right_setting", dry_run.GOOD_CHAIN_SUFFIX)

    def _record(**overrides) -> dict:
        record = {"pid": 9001, "self_exited": True, "returncode": 0, "timed_out": False}
        record.update(overrides)
        return {"exit_record": record}

    derived = _record(report_artifact_present=True,
                      returncode_basis=launch_services.RETURNCODE_DERIVED_BASIS)
    verdict = _judge("single_step_right_setting", derived, good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed,
           f"a derived basis with the report artifact present was refused: "
           f"{verdict.failure_reasons}")
    _check(any("derived" in line for line in verdict.basis),
           f"the derived basis must be quoted in the verdict: {verdict.basis}")

    # ... and never without the artifact that proves the instance ran.
    no_artifact = _record(report_artifact_present=False,
                          returncode_basis=launch_services.RETURNCODE_DERIVED_BASIS)
    verdict = _judge("single_step_right_setting", no_artifact, good.report,
                     good.state_before, good.state_after)
    _check(not verdict.passed and any("report_artifact_present" in reason
                                      for reason in verdict.failure_reasons),
           f"a derived basis without the artifact was accepted: {verdict.failure_reasons}")

    # The documented unavailable basis is an honest "no status", never a success.
    unavailable = _record(report_artifact_present=False,
                          returncode_basis=launch_services.RETURNCODE_UNAVAILABLE_BASIS)
    verdict = _judge("single_step_right_setting", unavailable, good.report,
                     good.state_before, good.state_after)
    _check(not verdict.passed and any("unavailable" in reason
                                      for reason in verdict.failure_reasons),
           f"the unavailable basis was accepted as success: {verdict.failure_reasons}")

    # A null returncode stays null, whatever basis is recorded next to it.
    null_status = _record(returncode=None, report_artifact_present=True,
                          returncode_basis=launch_services.RETURNCODE_DERIVED_BASIS)
    verdict = _judge("single_step_right_setting", null_status, good.report,
                     good.state_before, good.state_after)
    _check(not verdict.passed,
           f"a null returncode was accepted: {verdict.failure_reasons}")

    # A forked child the runner parented keeps its real, kernel-reported code.
    forked = _record(pid=4242)
    verdict = _judge("single_step_right_setting", forked, good.report,
                     good.state_before, good.state_after)
    _check(verdict.passed,
           f"a real exit code 0 was refused: {verdict.failure_reasons}")
    nonzero = _record(returncode=3)
    verdict = _judge("single_step_right_setting", nonzero, good.report,
                     good.state_before, good.state_after)
    _check(not verdict.passed, "a non-zero exit code was accepted")

    # The rule lives in the shared attempt checks, so every judge inherits it.
    for name in ("two_step_display_settings_scale", "continuity_progress_cancel",
                 "unknown_delivery_fault_recovery"):
        payload = _chain(name, dry_run.GOOD_CHAIN_SUFFIX)
        verdict = _judge(name, derived, payload.report, payload.state_before,
                         payload.state_after)
        _check(verdict.passed,
               f"{name} refused the derived exit status: {verdict.failure_reasons}")
    return ["exit status: a forked child's real code 0 passes and a non-zero code fails; a "
            "LaunchServices instance passes only on returncode=0 with a derived basis and "
            "a present report artifact; a null returncode and the unavailable basis fail "
            "closed, in every judge"]


# -------------------------------------------------------------- hygiene checks


def test_child_process_discipline(work_dir: Path) -> list[str]:
    registry = OwnedProcessRegistry()
    owned = spawn_owned_process(registry, "owned-sleep",
                                ["sleep", "30"], log_path=work_dir / "owned.log")
    decoy = subprocess.Popen(["sleep", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        _check(owned.poll() is None, "owned child did not start")
        _check(decoy.pid > 0, "decoy did not start")
        record = terminate_owned_process(owned)
        _check(record["terminated"] is True, f"owned child was not terminated: {record}")
        time.sleep(0.2)
        _check(decoy.poll() is None,
               "a process the runner did not spawn was signalled")
        # The registry tracks what the runner may stop; nothing else is registered.
        _check([process.pid for process in registry.all()] == [owned.pid],
               "registry contains a process the runner did not spawn")
        return ["own child terminated by SIGTERM; the decoy process was never signalled"]
    finally:
        decoy.kill()
        decoy.wait()


def test_freshness_gate_blocks_stale_binary(work_dir: Path) -> list[str]:
    identity = inspect_app_identity(paths.DEFAULT_DERIVED_DATA_APP)
    machine_note = (f"DerivedData binary built {identity.binary_modified_at_iso}, newest "
                    f"product source {identity.newest_product_source_path} at epoch "
                    f"{identity.newest_product_source_modified_at_epoch}")
    _check(identity.binary_is_fresh is False,
           f"expected the machine's current DerivedData binary to be stale: {machine_note}")
    _check(any("older than product sources" in reason for reason in identity.blocking_reasons),
           f"stale binary did not produce a blocking freshness reason: {identity.blocking_reasons}")

    # A synthetic fresh binary against the same sources must pass the freshness gate.
    fake_app = work_dir / "Her.app"
    (fake_app / "Contents/MacOS").mkdir(parents=True)
    (fake_app / "Contents/Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>'
        '<key>CFBundleIdentifier</key><string>com.yishuziyu.her</string>'
        '<key>CFBundleExecutable</key><string>Her</string>'
        '</dict></plist>', encoding="utf-8")
    fresh_binary = fake_app / "Contents/MacOS/Her"
    fresh_binary.write_bytes(b"#!/bin/sh\n")
    fresh_binary.chmod(0o755)
    newest_source_epoch = identity.newest_product_source_modified_at_epoch
    import os
    if newest_source_epoch:
        # Touch well past the newest product source so only freshness differs.
        os.utime(fresh_binary, (newest_source_epoch + 600, newest_source_epoch + 600))
    fresh_identity = inspect_app_identity(fake_app)
    _check(fresh_identity.binary_is_fresh is True,
           "a fresh synthetic binary was judged stale")
    _check(not any("older than product sources" in reason
                   for reason in fresh_identity.blocking_reasons),
           "freshness blocked a fresh binary")
    # The synthetic bundle still fails identity (unsigned, wrong codesign) — as it must.
    _check(fresh_identity.blocking_reasons,
           "an unsigned synthetic bundle was not blocked")
    return [f"stale DerivedData binary is BLOCKED ({machine_note}); "
            "a fresh synthetic binary passes the freshness gate while still failing "
            "signature identity"]


# ---------------------------------------------------------------- dry-run runs


def _machine_app_binary() -> Path:
    """The Mach-O this machine's DerivedData product actually contains."""
    identity = inspect_app_identity(paths.DEFAULT_DERIVED_DATA_APP)
    executable = identity.bundle_executable or paths.EXPECTED_BUNDLE_EXECUTABLE
    return paths.DEFAULT_DERIVED_DATA_APP / "Contents/MacOS" / executable


def _pending_scenario_names(app_binary: Path | None = None) -> list[str]:
    """Scenarios whose capability flag the given binary does not contain.

    The same rule the runner uses: a scenario is pending-integrator-run exactly
    when the work order that owns its probe is not merged into the built binary
    (its flag is absent). The expected dry-run exit code is therefore derived
    from the binary's real capability, not from an assumption about which work
    orders have merged here.
    """
    binary = app_binary if app_binary is not None else _machine_app_binary()
    pending: list[str] = []
    for scenario in load_scenarios():
        capability_flag = scenario.capability_flag
        if scenario.probe_mode == "unknown" and capability_flag:
            if not binary_supports_flag(binary, capability_flag):
                pending.append(scenario.name)
    return pending


def _run_dry_run(work_dir: Path, failure_injection: bool) -> tuple[int, dict, dict]:
    out_dir = work_dir / ("dry-run-failures" if failure_injection else "dry-run-good")
    options = RunOptions(
        app_path_argument=None,
        out_dir=out_dir,
        mode="dry_run",
        dry_run_failure_injection=failure_injection,
    )
    exit_code = run_acceptance(options)
    result = evidence.read_json(out_dir / "result.json")
    app_identity = evidence.read_json(out_dir / "app-identity.json")
    return exit_code, result, app_identity


def test_dry_run_full_pipeline_twice_consistent(work_dir: Path) -> list[str]:
    first_code, first_result, _ = _run_dry_run(work_dir / "first", failure_injection=False)
    # The exit code depends on what this binary can actually do: a scenario whose
    # owning work order has not merged is pending-integrator-run, so the honest
    # exit is non-zero; when every scenario's capability is present, the same
    # pipeline has nothing left to be honest about except a clean 0.
    # The rule itself, proven against synthetic binaries so the assertion keeps
    # its meaning on either machine: a capability the binary lacks is pending
    # (non-zero exit is honest), a capability it has is not (zero is honest).
    capable = work_dir / "binary-with-receipt-loss-probe"
    capable.write_bytes(b"\x00fake-macho" + b"--receipt-loss-probe" + b"\x00rest")
    incapable = work_dir / "binary-without-receipt-loss-probe"
    incapable.write_bytes(b"\x00fake-macho--voice-task-probe\x00rest")
    _check(_pending_scenario_names(capable) == [],
           f"a binary that contains the probe must leave nothing pending: "
           f"{_pending_scenario_names(capable)}")
    _check(_pending_scenario_names(incapable) == ["unknown_delivery_fault_recovery"],
           f"a binary without the probe must leave the scenario pending: "
           f"{_pending_scenario_names(incapable)}")

    pending = _pending_scenario_names()
    expected_code = 1 if pending else 0
    capability_note = (f"pending scenarios in this binary: {pending or 'none'}")
    _check(first_code == expected_code,
           f"good dry-run must exit {expected_code} ({capability_note}), got {first_code}")
    _check(not any(scenario["status"] == "failed" for scenario in first_result["scenarios"]),
           "the good dry-run has a failed scenario")
    _check(first_result["summary"]["pending_integrator_run"] == pending,
           f"pending scenario list wrong: {first_result['summary']} vs {pending}")
    _check(first_result["proof"] is False, "dry run claimed proof")
    _check(first_result["mode"] == "dry_run", "dry run mislabeled")
    _check(first_result["environment"]["fixture"]["port_released_after_stop"] is True,
           "dry run left the fixture port occupied")
    _check(first_result["environment"]["cleanup"]["owned_processes_remaining"] == 0,
           "dry run left owned processes running")

    second_dir = work_dir / "second"
    second_options = RunOptions(app_path_argument=None, out_dir=second_dir, mode="dry_run")
    _check(not port_accepts_connections(paths.FIXTURE_HOST, paths.FIXTURE_PORT),
           "second run started while the port was still occupied by the first")
    second_code = run_acceptance(second_options)
    second_result = evidence.read_json(second_dir / "result.json")
    _check(second_code == expected_code, "second dry run did not match the first run's exit code")
    first_statuses = {scenario["name"]: scenario["status"] for scenario in first_result["scenarios"]}
    second_statuses = {scenario["name"]: scenario["status"] for scenario in second_result["scenarios"]}
    _check(first_statuses == second_statuses,
           f"two dry runs disagreed: {first_statuses} vs {second_statuses}")
    for scenario in first_result["scenarios"]:
        _check(scenario["status"] in ("passed", "pending_integrator_run"),
               f"unexpected dry-run verdict: {scenario['status']}")
    return [f"two consecutive dry runs agree, exit {expected_code} ({capability_note}), "
            "port free between runs, no owned processes left, and proof=False throughout"]


def test_dry_run_failure_injection_is_detected(work_dir: Path) -> list[str]:
    code, result, _ = _run_dry_run(work_dir, failure_injection=True)
    _check(code == 1, "injected bad evidence did not produce a non-zero exit")
    statuses = {scenario["name"]: scenario["status"] for scenario in result["scenarios"]}
    for name in ("single_step_right_setting", "two_step_display_settings_scale",
                 "continuity_progress_cancel"):
        _check(statuses.get(name) == "failed",
               f"injected failure for {name} was not detected: {statuses}")
        scenario = next(item for item in result["scenarios"] if item["name"] == name)
        _check(scenario["failure_reasons"], f"{name} failed without recorded reasons")
    return ["every injected bad chain failed the run with recorded reasons and exit code 1"]


def test_interrupted_run_still_writes_report(work_dir: Path) -> list[str]:
    """An interrupted run must still produce a readable, non-PASS report.

    Part 1 proves the signal handler's contract (a signal only sets the abort
    flag and never raises, so the run can settle what is in flight), part 2
    proves the exit codes, part 3 interrupts the real dry-run pipeline with a
    real SIGINT and reads the package back from disk. No app, provider or
    desktop is involved, and the user's Her is never signalled.
    """
    # 1. The handler contract: set the flag, never raise.
    state = AbortState()
    installed = _install_abort_signal_handlers(state)
    try:
        signal.raise_signal(signal.SIGINT)
        _check(state.requested and state.signal_name == "SIGINT",
               f"SIGINT did not set the abort flag: {state}")
        _check(_abort_exit_code(state) == SIGINT_EXIT_CODE,
               f"SIGINT must exit {SIGINT_EXIT_CODE}: {_abort_exit_code(state)}")
        _check(_abort_exit_code(AbortState.for_signal(signal.SIGTERM)) != 0,
               "SIGTERM must exit non-zero")
        _check(_abort_exit_code(AbortState()) != 0, "an abort without a signal must exit non-zero")
    finally:
        _restore_signal_handlers(installed)

    # 2. An abort requested before the scenarios still writes the whole package.
    pre_run_dir = work_dir / "abort-before-scenarios"
    pre_code = run_acceptance(
        RunOptions(app_path_argument=None, out_dir=pre_run_dir, mode="dry_run"),
        abort=AbortState.for_signal(signal.SIGINT),
    )
    pre_result = evidence.read_json(pre_run_dir / "result.json")
    _check(pre_code == SIGINT_EXIT_CODE, f"aborted run exited {pre_code}, expected {SIGINT_EXIT_CODE}")
    _check(pre_result["passed"] is False, "an aborted run was recorded as passed")
    _check(pre_result["environment"]["abort"]["signal_name"] == "SIGINT",
           f"the report does not record the interrupt: "
           f"{pre_result['environment'].get('abort')}")
    _check(all(scenario["abort"]["status"] == "not_run" for scenario in pre_result["scenarios"]),
           f"every scenario must be not_run: "
           f"{[s['abort']['status'] for s in pre_result['scenarios']]}")
    _check(pre_result["environment"]["fixture"]["not_started"] is True,
           "a run aborted before the fixture must say the fixture never started")

    # 3. A real SIGINT in the middle of the pipeline: the in-flight attempt is
    #    settled, the loop starts no new work, and the report is still written.
    out_dir = work_dir / "sigint-mid-run"
    artifacts = out_dir / "scenario-artifacts"
    delivered = threading.Event()

    def _interrupt() -> None:
        deadline = time.monotonic() + 60.0
        while time.monotonic() < deadline:
            if any(artifacts.glob("*/run-1")):
                os.kill(os.getpid(), signal.SIGINT)
                delivered.set()
                return
            time.sleep(0.01)

    interrupter = threading.Thread(target=_interrupt, daemon=True)
    interrupter.start()
    exit_code = run_acceptance(RunOptions(app_path_argument=None, out_dir=out_dir,
                                          mode="dry_run"))
    interrupter.join(timeout=5.0)
    _check(delivered.is_set(), "the synthetic SIGINT was never delivered")

    _check((out_dir / "result.json").is_file(), "an interrupted run wrote no result.json")
    result = evidence.read_json(out_dir / "result.json")
    _check(exit_code == SIGINT_EXIT_CODE,
           f"SIGINT must exit {SIGINT_EXIT_CODE}, got {exit_code}")
    _check(result["exit_code"] == SIGINT_EXIT_CODE,
           f"result.json recorded exit_code={result['exit_code']}")
    _check(result["passed"] is False, "an interrupted run was recorded as passed")
    _check(result["proof"] is False, "an interrupted run claimed proof")
    _check(result["environment"]["abort"]["signal_name"] == "SIGINT",
           f"the report does not record the interrupt: {result['environment'].get('abort')}")
    aborted = [scenario for scenario in result["scenarios"] if scenario.get("aborted")]
    _check(aborted, "no scenario recorded the interruption")
    _check(all(scenario["status"] != "passed" for scenario in aborted),
           f"an aborted scenario was recorded as passed: {[s['status'] for s in aborted]}")
    _check(all(scenario["status"] == "failed" for scenario in aborted),
           f"an aborted scenario must be a non-PASS failed status: "
           f"{[s['status'] for s in aborted]}")
    _check(all(scenario["abort"]["status"] in ("aborted", "not_run")
               and scenario["failure_reasons"] for scenario in aborted),
           f"aborted scenarios must name aborted/not_run with a reason: "
           f"{[s['abort']['status'] for s in aborted]}")
    _check(result["environment"]["cleanup"]["owned_processes_remaining"] == 0,
           "an interrupted run left owned processes running")
    _check(result["environment"]["fixture"]["port_released_after_stop"] is True,
           "an interrupted run left the fixture port occupied")
    _check(evidence.validate_result_schema(result) == [],
           f"the interrupted package failed the evidence schema: "
           f"{evidence.validate_result_schema(result)}")
    for scenario in aborted:
        for artifact in scenario["abort"]["attempt_artifacts"]:
            path = Path(artifact)
            _check(path.is_file(), f"settled attempt is not on disk: {artifact}")
            evidence.read_json(path)  # complete JSON: the per-attempt write is atomic
    return [f"SIGINT handler sets a flag and never raises; exit {SIGINT_EXIT_CODE} for SIGINT "
            "and non-zero for any other abort; an interrupted dry run still wrote result.json "
            "with passed=false, every scenario recorded as aborted/not_run with a reason, and "
            "the attempts it had already settled on disk one by one"]


def test_dry_run_artifacts_have_no_secrets(work_dir: Path) -> list[str]:
    out_dir = work_dir / "secret-scan-run"
    options = RunOptions(app_path_argument=None, out_dir=out_dir, mode="dry_run")
    run_acceptance(options)
    findings: list[str] = []
    for path in sorted(out_dir.rglob("*")):
        if path.is_file():
            findings.extend(evidence.scan_file_for_secrets(path))
    _check(findings == [], f"secret-shaped content in dry-run artifacts: {findings}")
    _check((out_dir / "commands.txt").is_file() and (out_dir / "README.md").is_file(),
           "commands.txt or README.md missing from the package")
    return ["the full dry-run package scans clean of secret-shaped content and includes "
            "commands.txt and README.md"]


def test_scenario_definitions_are_consistent() -> list[str]:
    scenarios = load_scenarios()
    names = [scenario.name for scenario in scenarios]
    for required in ("single_step_right_setting", "two_step_display_settings_scale",
                     "continuity_progress_cancel", "unknown_delivery_fault_recovery"):
        _check(required in names, f"required scenario {required!r} is missing")
    for scenario in scenarios:
        _check(all(utterance.strip() for utterance in scenario.utterances),
               f"{scenario.name} has an empty utterance")
        _check(scenario.probe_mode in ("voice_task", "voice_continuity", "unknown",
                                       "desktop_task", "voice_route", "jev_fanout"),
               f"{scenario.name} has unknown probe mode {scenario.probe_mode!r}")
        if scenario.probe_mode == "voice_continuity":
            _check(len(scenario.utterances) == 2,
                   f"{scenario.name} needs exactly two utterances (progress, cancel)")
        if scenario.probe_mode == "unknown":
            _check(scenario.reproduction.get("one_command"),
                   f"{scenario.name} must carry the integrator reproduction command")
    return ["all four required scenarios are defined with consistent probe modes, "
            "non-empty utterances and reproduction metadata"]


def test_probe_execution_lifecycle(work_dir: Path) -> list[str]:
    """Real spawn/report/cleanup plumbing with a fake probe binary (no app)."""
    fake_report = {
        "completed": True,
        "calls": [{"name": "act_on_screen",
                   "arguments": json.dumps({"goal": "点击右边的设置按钮",
                                            "action": "click", "region": "right"},
                                           ensure_ascii=False)}],
        "tool_results": [], "rendered_texts": [],
    }
    fake_report_path = work_dir / "fake-report.json"
    fake_report_path.write_text(json.dumps(fake_report, ensure_ascii=False), encoding="utf-8")

    fake_binary = work_dir / "fake-her-probe"
    fake_binary.write_text(
        "#!/bin/bash\n"
        "mkdir -p \"$4\"\n"
        f"cp {fake_report_path} \"$4/realtime.json\"\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake_binary.chmod(0o755)

    registry = OwnedProcessRegistry()
    request = ProbeRequest(
        mode="voice_task", app_binary=fake_binary,
        working_out_dir=work_dir / "probe-out",
        utterance_pcm_paths=[work_dir / "utterance.pcm"],
        report_file_name="realtime.json",
    )
    (work_dir / "utterance.pcm").write_bytes(b"\x00\x01" * 120)
    result = run_probe(request, registry, timeout_seconds=30.0)
    _check(result.exit_record["self_exited"] is True and result.exit_record["returncode"] == 0,
           f"fake probe did not exit cleanly: {result.exit_record}")
    _check(result.report is not None and result.report.get("completed") is True,
           f"fake probe report was not loaded: {result.report_error}")
    _check("realtime.json" in result.output_files, f"output files wrong: {result.output_files}")
    _check(not registry.running(), "fake probe process was left running")
    _check((result.child.log_path or Path("/nonexistent")).is_file(),
           "probe log was not captured")

    # A probe that exits cleanly but writes no report must fail closed.
    silent_binary = work_dir / "silent-probe"
    silent_binary.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    silent_binary.chmod(0o755)
    silent_request = ProbeRequest(
        mode="voice_task", app_binary=silent_binary,
        working_out_dir=work_dir / "silent-out",
        utterance_pcm_paths=[work_dir / "utterance.pcm"],
        report_file_name="realtime.json",
    )
    silent_result = run_probe(silent_request, registry, timeout_seconds=30.0)
    _check(silent_result.report is None and "did not write" in (silent_result.report_error or ""),
           f"missing report was not detected: {silent_result.report_error}")

    # A probe that never exits must be stopped by the runner (own child only).
    hanging_binary = work_dir / "hanging-probe"
    hanging_binary.write_text("#!/bin/bash\nsleep 60\n", encoding="utf-8")
    hanging_binary.chmod(0o755)
    hanging_request = ProbeRequest(
        mode="voice_task", app_binary=hanging_binary,
        working_out_dir=work_dir / "hanging-out",
        utterance_pcm_paths=[work_dir / "utterance.pcm"],
        report_file_name="realtime.json",
    )
    hanging_result = run_probe(hanging_request, registry, timeout_seconds=2.0)
    _check(hanging_result.exit_record["timed_out"] is True,
           f"hanging probe was not marked timed out: {hanging_result.exit_record}")
    _check(hanging_result.exit_record.get("killed_after_grace") is True
           or hanging_result.exit_record.get("terminated") is True,
           f"hanging probe was not terminated: {hanging_result.exit_record}")
    time.sleep(0.2)
    _check(hanging_result.child.poll() is not None, "terminated probe child is still alive")
    _check(not registry.running(), "processes left running after the probe tests")
    return ["fake probe report loaded and cleaned up; silent probe failed closed; "
            "hanging probe terminated by the runner with the timeout recorded"]


# ------------------------------------------------------------ preflight gate


def test_preflight_gate_blocks_and_continues(work_dir: Path) -> list[str]:
    """The in-app --preflight gate decision, proven with fake binaries.

    No real app, provider, desktop or permission prompt is involved: this is a
    runner unit test of the BLOCK-vs-continue rule only.
    """
    registry = OwnedProcessRegistry()

    def _fake_preflight_app(name: str, payload: dict | None) -> Path:
        # The `--preflight` string is embedded (a comment) so binary_supports_flag
        # detects it exactly as it would in the real DEBUG Mach-O. When a payload
        # is supplied the script copies it to $2 (the runner-passed report path).
        binary = work_dir / name
        if payload is None:
            script = "#!/bin/bash\n# handles --preflight <output>\nexit 0\n"
        else:
            payload_path = work_dir / f"{name}.payload.json"
            payload_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            script = ("#!/bin/bash\n"
                      "# handles --preflight <output>\n"
                      f'cp "{payload_path}" "$2"\n'
                      "exit 0\n")
        binary.write_text(script, encoding="utf-8")
        binary.chmod(0o755)
        return binary

    failing = {
        "bundle_identifier": "com.yishuziyu.her", "accessibility_trusted": False,
        "frontmost_bundle_id": "com.apple.finder",
        "required_checks": {"accessibility": False},
        "blocked_reasons": ["accessibility_not_trusted"],
    }
    passing = {
        "bundle_identifier": "com.yishuziyu.her", "accessibility_trusted": True,
        "frontmost_bundle_id": "com.apple.finder",
        "required_checks": {"accessibility": True},
        "blocked_reasons": [],
    }

    # 1. Older build without the flag: never a verdict; continue with supported=False.
    older = work_dir / "older-her"
    older.write_bytes(b"\x00fake-macho without the preflight flag\n")
    older.chmod(0o755)
    evidence, reasons = _preflight_gate(older, registry, work_dir / "pf-older")
    _check(evidence == {"supported": False},
           f"older build must record exactly supported=false: {evidence}")
    _check(reasons == [], f"older build must not block: {reasons}")

    # 2. Supported, preconditions failed: BLOCK, carrying the app's exact reason
    #    and the whole preflight JSON.
    blocked_app = _fake_preflight_app("blocked-her", failing)
    _check(binary_supports_flag(blocked_app, PREFLIGHT_FLAG), "fake --preflight not detected")
    evidence, reasons = _preflight_gate(blocked_app, registry, work_dir / "pf-blocked")
    _check(evidence.get("supported") is True, f"supported app mislabeled: {evidence}")
    _check(evidence.get("clear") is False, f"failed preflight must not be clear: {evidence}")
    _check("accessibility_not_trusted" in reasons,
           f"the app's exact blocked reason was not surfaced: {reasons}")
    _check(evidence["report"]["required_checks"]["accessibility"] is False,
           "the whole preflight JSON was not attached to the evidence")

    # 3. Supported, preconditions met: continue (clear), no reasons.
    ok_app = _fake_preflight_app("ok-her", passing)
    evidence, reasons = _preflight_gate(ok_app, registry, work_dir / "pf-ok")
    _check(evidence.get("clear") is True and reasons == [],
           f"passing preflight must continue: clear={evidence.get('clear')} reasons={reasons}")

    # 4. Supported but wrote no report: fail closed (cannot prove preconditions).
    silent = run_preflight(_fake_preflight_app("silent-her", None), registry,
                           work_dir / "pf-silent", timeout_seconds=30.0)
    _check(silent.report is None, "silent preflight should have produced no report")
    _check(silent.clear is False and silent.blocking_reasons,
           "a supported preflight with no report must fail closed")

    _check(not registry.running(), "a preflight child was left running by the test")
    return ["preflight gate: older build records supported=false and continues; failing "
            "preconditions BLOCK with the app's exact reason and whole JSON; passing "
            "preconditions continue; a report-less supported preflight fails closed"]


# --------------------------------------------------------- machine preflight


def test_machine_preflight_port_occupancy(work_dir: Path) -> list[str]:
    """Port occupancy is decided by a connect attempt that disturbs nothing.

    A real listener on an ephemeral port proves the occupied branch reports the
    port (and leaves the listener alive and listening), and closing it proves
    the same probe then reports the port free. This is why a run can be BLOCKED
    on a held port without the preflight ever killing a leftover process.
    """
    from . import machine_preflight

    # Port 0 lets the kernel hand out a free port: the test cannot collide with
    # anything, and nothing has to be started to fake an occupancy.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((paths.FIXTURE_HOST, 0))
    listener.listen(8)
    probe_port = listener.getsockname()[1]
    try:
        occupied = machine_preflight.check_port(
            "probe-port", paths.FIXTURE_HOST, probe_port, "the test's own listener")
        _check(occupied["ok"] is False, f"an occupied port was reported ok: {occupied}")
        _check(occupied["evidence"]["port_accepts_connections"] is True,
               f"the occupancy probe did not observe the listener: {occupied}")
        _check(str(probe_port) in occupied["detail"],
               f"the occupied detail must name the port: {occupied}")
        # The probe connected and closed its own socket; the listener survives.
        _check(port_accepts_connections(paths.FIXTURE_HOST, probe_port),
               "the occupancy probe disturbed the foreign listener it found")
        _check(listener.fileno() != -1, "the existing listener was closed by the probe")
    finally:
        listener.close()
        time.sleep(0.2)
    free = machine_preflight.check_port(
        "probe-port", paths.FIXTURE_HOST, probe_port, "the test's own listener")
    _check(free["ok"] is True, f"a released port was reported occupied: {free}")
    _check(free["evidence"]["port_accepts_connections"] is False,
           f"the free probe disagreed: {free}")
    return [f"port {probe_port}: occupied reported and the listener untouched; "
            "released port reported free - a connect-only occupancy probe"]


def test_machine_preflight_frontmost_identity_forms(work_dir: Path) -> list[str]:
    """Both `lsappinfo front` shapes must resolve to one proven identity.

    One build lists the bundle id outright; this machine's shape prints only an
    ASN ending in a trailing colon, which must be resolved with the read-only
    `lsappinfo info <ASN>` - never inferred from the ASN text. browser_stage owns
    that machinery and machine_preflight consumes it, so this drives the real
    path with scripted `lsappinfo` output and checks the judgment the preflight
    builds on top: expected module ready, foreign module a concrete missing
    item, unresolvable ASN a fail-closed missing item (no guess).
    """
    from . import browser_stage, machine_preflight

    expected = "com.apple.Safari"
    asn = "ASN:0x0-0x26be6bc:"
    # browser_stage cleans the trailing colon before it asks for the identity.
    resolved_asn = "ASN:0x0-0x26be6bc"
    def _capture(stdout: str = "", returncode: int = 0, stderr: str = "") -> dict:
        return {"argv": [], "returncode": returncode, "stdout": stdout,
                "stderr": stderr, "timed_out": False, "error": None}

    def _scripted(two_commands) -> dict:
        real_run_capture = browser_stage.run_capture
        browser_stage.run_capture = two_commands
        try:
            return machine_preflight.check_frontmost_app(expected)
        finally:
            browser_stage.run_capture = real_run_capture

    # Shape 1: the listing names the bundle id directly.
    bundle_direct = _scripted(
        lambda argv, timeout_seconds: _capture("com.apple.Safari ASN:0x0-0x26ba0c:")
        if argv[-1] == "front" else _capture(stderr="unused info call", returncode=1))
    _check(bundle_direct["ok"] is True, f"a direct bundle listing was rejected: {bundle_direct}")
    _check(bundle_direct["evidence"]["observed_bundle_id"] == expected,
           f"the direct listing did not identify the bundle: {bundle_direct}")

    # Shape 2: an ASN with the trailing colon, resolved through lsappinfo info.
    def _asn_commands(argv: list[str], timeout_seconds: float) -> dict:
        if argv[-1] == "front":
            return _capture(asn)
        if argv[1] == "info" and argv[2] == resolved_asn:
            return _capture('bundleID="com.apple.Safari"')
        return _capture(stderr="unexpected lsappinfo call", returncode=1)

    asn_form = _scripted(_asn_commands)
    _check(asn_form["ok"] is True, f"the ASN shape did not resolve to the bundle: {asn_form}")
    _check(asn_form["evidence"]["observed_bundle_id"] == expected,
           f"the ASN shape resolved to the wrong identity: {asn_form}")
    asn_observed = [observation for observation in asn_form["evidence"]["frontmost_observations"]
                    if observation.get("frontmost_asn")]
    _check(asn_observed and asn_observed[0]["frontmost_asn"] == resolved_asn,
           f"the resolved observation must record the ASN it resolved: {asn_form}")
    _check('bundleID="com.apple.Safari"' in asn_observed[0]["lsappinfo_info_stdout"],
           f"the lsappinfo info output is missing from the evidence: {asn_form}")

    # A foreign identity is a concrete missing item, not a warning.
    mismatch = _scripted(
        lambda argv, timeout_seconds: _capture(asn) if argv[-1] == "front"
        else _capture('bundleID="com.apple.finder"'))
    _check(mismatch["ok"] is False, f"a foreign frontmost app was accepted: {mismatch}")
    _check(mismatch["evidence"]["observed_bundle_id"] == "com.apple.finder"
           and "com.apple.finder" in mismatch["detail"],
           f"the mismatch must name the observed identity: {mismatch}")

    # An ASN that refuses to resolve fails closed: no identity is invented.
    unresolved = _scripted(
        lambda argv, timeout_seconds: _capture(asn) if argv[-1] == "front"
        else _capture(stderr="kill message from the shell", returncode=3))
    _check(unresolved["ok"] is False, f"an unresolved ASN passed: {unresolved}")
    _check(unresolved["evidence"]["observed_bundle_id"] == "",
           f"an unresolved ASN must not carry an invented identity: {unresolved}")
    _check(unresolved["detail"].startswith("frontmost identity could not be established"),
           f"the failure must say the identity could not be established: {unresolved}")
    return ["frontmost identity: a direct bundle listing and the trailing-colon ASN "
            "form (resolved via lsappinfo info <ASN>) are both judged against the "
            "expected module; a foreign identity is a named missing item and an "
            "unresolvable ASN fails closed without an invented identity"]


def test_machine_preflight_binary_freshness_judgment(work_dir: Path) -> list[str]:
    """Freshness is decided by mtime comparison, never by a claim.

    Two synthetic bundles differ only in the binary's mtime relative to the
    newest product source (the same glob collection app_identity audits): one
    older is not_ready with the stale detail, one newer is ready for this check.
    The comparison itself stays app_identity's, so this proves only the
    preflight's mapping from that judgment to its verdict.
    """
    from . import machine_preflight

    def _bundle(tag: str, offset_seconds: float, newest_epoch: float | None) -> Path:
        app = work_dir / f"Her-{tag}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>'
            '<key>CFBundleIdentifier</key><string>com.yishuziyu.her</string>'
            '<key>CFBundleExecutable</key><string>Her</string>'
            '</dict></plist>', encoding="utf-8")
        binary = app / "Contents/MacOS/Her"
        binary.write_bytes(b"#!/bin/sh\n")
        binary.chmod(0o755)
        if newest_epoch:
            stamp = newest_epoch + offset_seconds
        else:
            stamp = 0.0
        os.utime(binary, (stamp, stamp))
        return app

    stale = machine_preflight.check_binary_freshness(_bundle("stale", -3600.0, None))
    newest_epoch = stale["evidence"]["newest_product_source_mtime_epoch"]
    _check(newest_epoch is not None and stale["evidence"]["product_sources_checked"] > 0,
           f"the freshness check did not locate product sources: {stale}")
    _check(stale["ok"] is False, f"a stale binary was accepted: {stale}")
    _check(stale["evidence"]["binary_is_fresh"] is False and "stale" in stale["detail"],
           f"the stale detail is missing: {stale}")

    fresh = machine_preflight.check_binary_freshness(_bundle("fresh", 600.0, newest_epoch))
    _check(fresh["ok"] is True, f"a fresh binary was refused: {fresh}")
    _check(fresh["evidence"]["binary_is_fresh"] is True,
           f"freshness evidence disagrees: {fresh}")

    # A missing bundle cannot be judged either; the check fails closed.
    missing = machine_preflight.check_binary_freshness(work_dir / "Her-absent.app")
    _check(missing["ok"] is False, f"a missing app passed the freshness check: {missing}")
    _check("missing" in missing["detail"] or "does not exist" in missing["detail"],
           f"the missing-app detail must say so: {missing}")
    return [f"a binary older than the newest product source (epoch {newest_epoch}) is "
            "not_ready with a stale detail; the same bundle 600s newer is ready; a "
            "missing bundle fails closed - all via app_identity's comparison"]


def test_machine_preflight_user_her_process_record(work_dir: Path) -> list[str]:
    """The user Her record is a record: taken, parsed, and never signalled.

    The preflight lists processes with `ps -Ao pid=,lstart=,command=` and keeps
    every line whose command names the Her Mach-O, carrying pid, binary and
    launch start. A successful listing is the passing case even when a Her is
    running (that instance must survive the run), and a listing that cannot be
    taken fails closed because no such record could protect it.
    """
    from . import machine_preflight

    listing = (
        "    1 Fri Sep 18 13:52:06 2026     /sbin/launchd\n"
        "10531 Tue Sep 22 09:15:03 2026     /Users/me/Library/Developer/Xcode/DerivedData/"
        "tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq/Build/Products/Debug/Her.app/Contents/MacOS/Her\n"
        "  337 Fri Sep 18 13:54:29 2026     /usr/libexec/logd\n"
        "10534 Tue Sep 22 09:15:11 2026     grep Her.app/Contents/MacOS/Her --color\n"
        "10540 Wed Sep 23 10:02:11 2026     /Volumes/Storage/Her.app/Contents/MacOS/Her\n"
    )
    entries = machine_preflight.parse_ps_listing(listing, machine_preflight.HER_BINARY_SUBSTRING)
    _check([entry["pid"] for entry in entries] == [10531, 10534, 10540],
           f"the listing parse kept the wrong pids: {entries}")
    _check(entries[0]["started_at"] == "Tue Sep 22 09:15:03 2026"
           and entries[0]["binary"].endswith("Her.app/Contents/MacOS/Her"),
           f"the recorded entry lost its launch time or binary: {entries[0]}")
    _check("grep" in entries[1]["command"],
           f"a command line that merely names the pattern was dropped: {entries[1]}")

    real_capture = machine_preflight._capture_text
    machine_preflight._capture_text = (
        lambda argv, timeout_seconds: {"argv": [], "returncode": 1, "stdout": "",
                                       "stderr": "ps: permission denied",
                                       "timed_out": False, "error": None})
    try:
        failed = machine_preflight.check_user_her_processes()
    finally:
        machine_preflight._capture_text = real_capture
    _check(failed["ok"] is False,
           f"a listing that could not be taken was accepted: {failed}")
    _check("record" in failed["detail"],
           f"the failed listing must say the user Her record could not be produced: {failed}")

    recorded = machine_preflight.check_user_her_processes()
    _check(recorded["ok"] is True,
           f"a successful listing must pass even with a Her running: {recorded}")
    _check(isinstance(recorded["evidence"]["processes"], list),
           f"the record must carry the parsed entries: {recorded}")
    # Recorded only: a running Her survives this check by construction - the
    # preflight's whole vocabulary here is ps, lstart and command strings.
    _check("recorded" in recorded["detail"] or "no user Her process" in recorded["detail"],
           f"the live record must say what it found: {recorded}")
    return ["ps listing parse keeps pid/binary/launch-start for every Her-named command "
            "(including a bystander that only names the path); a failed listing fails "
            "closed; a successful one passes and records, never signals"]


# --------------------------------------------------------- run preconditions


def _unestablished_frontmost_stage(stop_reason: str, page_views: int = 7) -> dict:
    """A browser_stage result that could not prove Safari is frontmost.

    The shape is what `browser_stage.stage_controlled_page` /
    `reload_controlled_page` return when the wait ended unestablished: the
    controlled page did open (page_views moved) but the frontmost identity was
    never proven, and the exact reason is the only thing a caller may act on.
    """
    return {
        "url": paths.FIXTURE_URL,
        "browser": paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER,
        "opened": True,
        "page_views_after_open": page_views,
        "page_views_after_reload": page_views,
        "became_frontmost": False,
        "frontmost_established": False,
        "frontmost_bundle_id": "",
        "frontmost_observed_bundle_id": "com.apple.finder",
        "frontmost_stop_reason": stop_reason,
        "frontmost_identity": {
            "frontmost_established": False,
            "frontmost_bundle_id": "",
            "frontmost_observed_bundle_id": "com.apple.finder",
            "frontmost_stop_reason": stop_reason,
            "frontmost_attempts": 3,
        },
    }


def test_frontmost_gate_blocks_before_any_call(work_dir: Path) -> list[str]:
    """An unproven foreground stops a scenario; it never becomes a warning.

    Part 1 pins the gate's decision function, part 2 drives one real scenario
    through it with a stubbed browser stage and a probe entrypoint that fails the
    test if it is ever reached, and part 3 runs the whole full-mode pipeline with
    the staged page unproven. No Safari, no app, no provider and no desktop: the
    runner's own rule is what is under test.
    """
    stop_reason = "frontmost app is com.apple.finder, not the controlled browser com.apple.Safari"
    stage = _unestablished_frontmost_stage(stop_reason)

    # 1. The gate only ever accepts a positive proof. A dry-run's skipped stage
    #    and an established wait are "nothing to block"; everything else - an
    #    unproven observation, a missing reason, a stage that reports no
    #    frontmost fact at all - blocks rather than letting a desktop action
    #    through on an unproven foreground.
    _check(orchestration._frontmost_stop_reasons({"skipped": True}) == [],
           "the dry-run skip record was misread as an unproven foreground")
    _check(orchestration._frontmost_stop_reasons(
        dict(stage, frontmost_established=True, frontmost_stop_reason="")) == [],
           "an established frontmost wait must not block a scenario")
    _check(orchestration._frontmost_stop_reasons(stage) == [stop_reason],
           "an unproven foreground must carry its exact stop reason")
    _check(orchestration._frontmost_stop_reasons(dict(stage, frontmost_stop_reason="")) != [],
           "an unproven foreground with no recorded reason must still block")
    _check(orchestration._frontmost_stop_reasons({"error": "staging failed"}) != [],
           "a stage that reports no frontmost fact at all must fail closed, not "
           "silently allow a desktop action")

    # 2. One scenario: BLOCKED with the exact reason, and no probe was started.
    scenario = _scenario_by_name("single_step_right_setting")

    class _StubBrowserStage:
        def __init__(self) -> None:
            self.reload_calls = 0

        def reload_controlled_page(self, _fixture, _previous_page_views):
            self.reload_calls += 1
            return dict(stage)

    class _StubFixture:
        def reset(self) -> dict:
            return {"selected": None, "clicks": 0, "menu_open": False, "events": []}

        def state(self) -> dict:
            return {"selected": None, "clicks": 0, "menu_open": False, "events": [],
                    "page_views": 6}

    def _no_probe(*_args, **_kwargs):
        raise SelfTestFailure("a probe (provider/Driver) call was started for a "
                              "scenario the frontmost gate had blocked")

    stubbed_stage = _StubBrowserStage()
    scenario_out_dir = work_dir / "scenario-out"
    real_stage, real_probe = orchestration.browser_stage, orchestration.run_probe
    orchestration.browser_stage = stubbed_stage
    orchestration.run_probe = _no_probe
    try:
        record = orchestration._run_scenario(
            scenario,
            RunOptions(app_path_argument=None, out_dir=scenario_out_dir, mode="full"),
            RunContext(mode="full", entrypoint="self-test",
                       app_path=work_dir / "Her.app", out_dir=scenario_out_dir,
                       started_at_iso="2026-01-01T00:00:00+00:00"),
            _StubFixture(), OwnedProcessRegistry(), {},
        )
    finally:
        orchestration.browser_stage, orchestration.run_probe = real_stage, real_probe

    _check(record["status"] == "blocked",
           f"an unproven foreground must BLOCK the scenario, got {record['status']}")
    _check(record["failure_reasons"] == [stop_reason],
           f"the exact stop reason must be the failure reason: {record['failure_reasons']}")
    _check(record["attempts"] == [],
           "a blocked scenario must not carry attempts (the probe never ran)")
    _check(record["frontmost_gate"]["stop_reasons"] == [stop_reason]
           and record["frontmost_gate"]["frontmost_established"] is False,
           f"the scenario did not record the gate decision: {record.get('frontmost_gate')}")
    _check(stubbed_stage.reload_calls == 1,
           "the foreground was not re-verified for the scenario that was blocked")

    # 3. The whole run: every scenario BLOCKED before any provider or Driver call,
    #    the fixture this run started stopped, and the package still valid.
    out_dir = work_dir / "frontmost-blocked-run"

    class _Identity:
        blocking_reasons: list[str] = []

        def to_dict(self) -> dict:
            return {"bundle_identifier": paths.EXPECTED_BUNDLE_IDENTIFIER}

    real = (orchestration.resolve_app_path, orchestration.inspect_app_identity,
            orchestration.stage_controlled_page)
    orchestration.resolve_app_path = lambda _argument: work_dir / "Her.app"
    orchestration.inspect_app_identity = lambda _app_path: _Identity()
    orchestration.stage_controlled_page = lambda _fixture, _previous: dict(stage)
    try:
        exit_code = run_acceptance(
            RunOptions(app_path_argument=None, out_dir=out_dir, mode="full")
        )
    finally:
        (orchestration.resolve_app_path, orchestration.inspect_app_identity,
         orchestration.stage_controlled_page) = real

    result = evidence.read_json(out_dir / "result.json")
    _check(exit_code == 1, f"a frontmost-blocked run must exit 1, got {exit_code}")
    _check(result["blocked_reason"] is not None
           and stop_reason in result["blocked_reason"],
           f"the report must name the exact stop reason: {result['blocked_reason']}")
    _check(all(scenario_record["status"] == "blocked"
               for scenario_record in result["scenarios"]),
           f"every scenario must be blocked: "
           f"{[s['status'] for s in result['scenarios']]}")
    _check(all(scenario_record["failure_reasons"][0] == stop_reason
               for scenario_record in result["scenarios"]),
           "a blocked scenario did not carry the exact stop reason")
    _check(not any(scenario_record["attempts"] for scenario_record in result["scenarios"]),
           "a blocked run reported attempts, which would mean a probe had run")
    _check(result["passed"] is False and result["proof"] is False,
           "a run blocked on the foreground must never be a pass or proof")
    _check(result["environment"]["frontmost_gate"]["frontmost_established"] is False,
           "the run did not record the frontmost gate decision")
    _check(result["environment"]["fixture"]["port_released_after_stop"] is True,
           "a frontmost-blocked run left the fixture port occupied")
    _check(result["environment"]["cleanup"]["owned_processes_remaining"] == 0,
           "a frontmost-blocked run left owned processes running")
    _check(evidence.validate_result_schema(result) == [],
           f"the blocked package failed the evidence schema: "
           f"{evidence.validate_result_schema(result)}")
    # This full-mode run held the machine-wide mutex for its whole life: it must
    # have given it back, or no later run could ever start.
    afterwards = run_mutex.acquire(run_mutex.default_lock_path(out_dir))
    _check(afterwards.acquired,
           "a finished (blocked) run did not release the run mutex")
    afterwards.release()
    return ["the foreground gate blocks one scenario with browser_stage's exact stop "
            "reason and never reaches the probe, and blocks the whole full-mode run "
            "(exit 1, every scenario blocked, fixture stopped) while leaving the "
            "evidence schema valid"]


def test_run_mutex_serializes_concurrent_runs(work_dir: Path) -> list[str]:
    """Two runners on one machine: the second is refused and changes nothing.

    Part 1 proves the lock's own semantics against a real second acquisition
    attempt. Part 2 starts a real second runner (the shipped CLI, as a separate
    process) while this test holds the lock, and reads its refusal back from
    disk: a distinct exit code, a report naming the active run's pid, and no
    fixture, port or /state touched by the refused run.
    """
    # ---- 1. The lock's semantics, with a live second acquisition attempt.
    active_out = work_dir / "active-run"
    lock_path = run_mutex.default_lock_path(active_out)
    _check(lock_path.parent == work_dir.resolve()
           and lock_path.name == run_mutex.LOCK_FILE_NAME,
           f"an evidence root outside out/acceptance must lock beside its own "
           f"--out: {lock_path}")
    shared_a = run_mutex.default_lock_path(work_dir / "out" / "acceptance" / "run-a")
    shared_b = run_mutex.default_lock_path(work_dir / "out" / "acceptance" / "run-b")
    _check(shared_a == shared_b and shared_a.parent.name == "acceptance"
           and shared_a.name == run_mutex.LOCK_FILE_NAME,
           f"two runs under one out/acceptance tree must share one lock file: "
           f"{shared_a} vs {shared_b}")
    _check(run_mutex.default_lock_path(work_dir / "nested" / "run") != lock_path,
           "an unrelated evidence root must not serialise this one")

    held = run_mutex.acquire(lock_path, owner={"mode": "full", "out_dir": str(active_out)})
    _check(held.acquired, f"the first acquisition must succeed: {held.detail}")
    try:
        second = run_mutex.acquire(lock_path)
        _check(second.state == "contended" and second.denied,
               f"a second acquisition while the lock is held must be refused as "
               f"contended, got state={second.state!r}")
        _check("another acceptance run is active" in second.denial_reason()
               and f"pid {os.getpid()}" in second.denial_reason(),
               f"the refusal must name the active run's pid: {second.denial_reason()}")
        # The held lock is undisturbed by the refused attempt: the record still
        # names this process and nobody else can take the lock either.
        holder = json.loads(lock_path.read_text(encoding="utf-8"))
        _check(holder.get("pid") == os.getpid(),
               f"the holder record was disturbed by the refused attempt: {holder}")
        _check(run_mutex.acquire(lock_path).denied,
               "the held lock stopped being held after a refused attempt")
    finally:
        held.release()

    # Releasing never deletes the file: replacing the inode would let a third run
    # lock a brand-new file while the first still holds the old one.
    _check(lock_path.is_file(), "releasing the lock deleted the lock file")
    reacquired = run_mutex.acquire(lock_path)
    _check(reacquired.acquired, "a released lock must be acquirable again")
    reacquired.release()

    # ---- 2. A real second runner: refused, reported, and touching nothing.
    second_out = work_dir / "second-runner"
    second_lock = run_mutex.default_lock_path(second_out)
    _check(second_lock == lock_path,
           f"the second runner must contend for this test's lock: {second_lock}")
    entrypoint = paths.repository_root() / "scripts/acceptance/her_voice_e2e.py"
    _check(entrypoint.is_file(), f"the runner entrypoint is missing: {entrypoint}")
    with run_mutex.hold(second_lock,
                        owner={"mode": "full", "out_dir": str(second_out)}):
        completed = subprocess.run(
            [sys.executable, str(entrypoint), "--dry-run", "--out", str(second_out)],
            cwd=str(paths.repository_root()), capture_output=True, text=True,
            timeout=180.0, check=False,
        )
    _check(completed.returncode == RUN_MUTEX_BLOCKED_EXIT_CODE,
           f"a second runner must exit {RUN_MUTEX_BLOCKED_EXIT_CODE}, got "
           f"{completed.returncode}: {completed.stderr.strip()[-400:]}")
    _check(f"pid {os.getpid()}" in completed.stdout,
           f"the refused run did not name the active run's pid: {completed.stdout}")
    reports = sorted(second_out.glob("blocked-by-active-run-*"))
    _check(len(reports) == 1,
           f"the refused run must write exactly one report directory: {reports}")
    report = evidence.read_json(reports[0] / "result.json")
    _check(report["exit_code"] == RUN_MUTEX_BLOCKED_EXIT_CODE,
           f"the refusal report recorded exit_code={report['exit_code']}")
    _check("another acceptance run is active" in (report["blocked_reason"] or "")
           and f"pid {os.getpid()}" in (report["blocked_reason"] or ""),
           f"the refusal report must name the active run: {report['blocked_reason']}")
    _check(report["environment"]["run_mutex"]["state"] == "contended"
           and report["environment"]["run_mutex"]["holder"]["pid"] == os.getpid(),
           f"the refusal report did not record the mutex evidence: "
           f"{report['environment'].get('run_mutex')}")
    _check(all(scenario_record["status"] == "blocked"
               for scenario_record in report["scenarios"])
           and report["scenarios"],
           "the refusal report must record every scenario as blocked")
    _check(report["passed"] is False and report["proof"] is False,
           "a refused run must never look like a pass")
    _check(not (second_out / "result.json").is_file(),
           "the refused run wrote into the shared --out directory, where it could "
           "overwrite the active run's package")
    _check(not port_accepts_connections(paths.FIXTURE_HOST, paths.FIXTURE_PORT),
           "the refused run started a fixture while another run owns the desktop")
    _check(evidence.validate_result_schema(report) == [],
           f"the refusal report failed the evidence schema: "
           f"{evidence.validate_result_schema(report)}")

    # ---- 3. SIGINT mid-run releases the lock: a run that was killed must never
    #         leave the machine serialised behind it.
    interrupted_out = work_dir / "sigint-run"
    interrupted_lock = run_mutex.default_lock_path(interrupted_out)
    child = subprocess.Popen(
        [sys.executable, str(entrypoint), "--dry-run", "--out", str(interrupted_out)],
        cwd=str(paths.repository_root()), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True,
    )
    try:
        deadline = time.monotonic() + 120.0
        while time.monotonic() < deadline:
            if any((interrupted_out / "scenario-artifacts").glob("*/run-1")):
                break
            time.sleep(0.02)
        _check(any((interrupted_out / "scenario-artifacts").glob("*/run-1")),
               "the interrupted run never reached a scenario")
        child.send_signal(signal.SIGINT)
        child.communicate(timeout=120.0)
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=30.0)
    _check(child.returncode == SIGINT_EXIT_CODE,
           f"an interrupted run must exit {SIGINT_EXIT_CODE}, got {child.returncode}")
    released = run_mutex.acquire(interrupted_lock)
    _check(released.acquired, "an interrupted run did not release the run mutex")
    released.release()
    _check(interrupted_lock.is_file(), "the lock file disappeared with the run")
    return [f"a second acquisition is refused as contended with the holder's pid, "
            f"the held lock and its record are undisturbed, the lock file survives "
            f"release, a real second runner exits {RUN_MUTEX_BLOCKED_EXIT_CODE} with "
            f"a report naming pid {os.getpid()} while starting no fixture, and a "
            f"SIGINTed run exits {SIGINT_EXIT_CODE} with the mutex released"]

# -------------------------------------------- provider argument shape monitor


def _write_json_file(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _probe_report(calls: list[dict]) -> dict:
    return {
        "route": "production_realtime_session",
        "completed": True, "error": "", "timed_out": False,
        "input_transcript": "点击右边的设置按钮",
        "calls": calls,
        "tool_results": [], "rendered_texts": [],
        "realtime_audio_bytes": 1000,
    }


def _act_on_screen(arguments) -> dict:
    return {"name": "act_on_screen", "arguments": arguments}


def test_provider_shape_monitor_detects_drift(work_dir: Path) -> list[str]:
    from . import provider_shapes

    drift_run = work_dir / "drift-run"
    _write_json_file(
        drift_run / "scenario-artifacts" / "single_step_right_setting" / "run-1" / "realtime.json",
        _probe_report([
            # The 01R shape: the click returned both top-level and inside steps.
            _act_on_screen(json.dumps({"goal": "点击右边的设置按钮", "intent": "new",
                                       "action": "click", "target_label": "设置",
                                       "region": "right",
                                       "steps": [{"action": "click", "target_label": "设置",
                                                  "region": "right"}]}, ensure_ascii=False)),
            # A label slot narrating a result instead of naming a control.
            _act_on_screen(json.dumps({"goal": "打开显示设置", "action": "click",
                                       "target_label": "页面已打开显示设置"}, ensure_ascii=False)),
            # A click with no target_label: a required contract field is gone.
            _act_on_screen(json.dumps({"goal": "点击右边的设置按钮", "action": "click",
                                       "region": "right"}, ensure_ascii=False)),
            # Top level and steps disagree: the redundancy became a conflict.
            _act_on_screen(json.dumps({"goal": "打开显示设置", "action": "click",
                                       "target_label": "显示设置",
                                       "steps": [{"action": "open_app",
                                                  "application": "com.apple.Safari"}]},
                                      ensure_ascii=False)),
            # Arguments that are not a JSON object at all.
            _act_on_screen("not-json"),
        ]))

    shapes = provider_shapes.record_shapes(drift_run)
    _check(shapes["calls_total"] == 5,
           f"5 recorded calls expected: {shapes['calls_total']}")
    _check(shapes["tool_names"] == {"act_on_screen": 5},
           f"tool name distribution wrong: {shapes['tool_names']}")
    _check(shapes["mixed_action_and_steps"]["count"] == 2,
           f"the redundant action+steps shape was missed: {shapes['mixed_action_and_steps']}")
    _check(shapes["steps_count_distribution"] == {"1": 2, "none": 2},
           f"steps-count distribution wrong: {shapes['steps_count_distribution']}")
    _check(shapes["result_phrase_labels"]["count"] == 1,
           f"the result-phrase label was missed: {shapes['result_phrase_labels']}")
    _check(set(shapes["result_phrase_labels"]["words_seen"]) >= {"页面已", "已打开"},
           f"unobservable words not surfaced: {shapes['result_phrase_labels']}")
    _check(shapes["missing_fields"]["count"] == 1,
           f"the target_label-less click was missed: {shapes['missing_fields']}")
    _check(shapes["conflicts"]["count"] == 1,
           f"the conflicting top-level/steps call was missed: {shapes['conflicts']}")
    _check(shapes["unparsable_arguments"] == 1,
           f"the unparsable arguments were missed: {shapes['unparsable_arguments']}")
    _check(len(shapes["drift_flags"]) == 5,
           f"every drift class must raise a flag: {shapes['drift_flags']}")
    _check(any("action+steps" in flag for flag in shapes["drift_flags"]),
           f"the 01R drift flag must name the shape: {shapes['drift_flags']}")
    shapes_file = drift_run / "shapes.json"
    _check(shapes_file.is_file(), f"record_shapes wrote no shapes.json: {shapes_file}")
    on_disk = json.loads(shapes_file.read_text(encoding="utf-8"))
    _check(on_disk["acceptance"] is False,
           "shapes.json must declare it is not acceptance evidence")
    _check("contract-drift" in on_disk["purpose"],
           f"shapes.json must state its drift-monitoring purpose: {on_disk['purpose']}")

    # A well-formed single-shape report must raise no drift flag.
    clean_run = work_dir / "clean-run"
    _write_json_file(
        clean_run / "scenario-artifacts" / "single_step_right_setting" / "run-1" / "realtime.json",
        _probe_report([
            _act_on_screen(json.dumps({"goal": "点击右边的设置按钮", "intent": "new",
                                       "action": "click", "target_label": "设置",
                                       "region": "right"}, ensure_ascii=False)),
        ]))
    clean = provider_shapes.record_shapes(clean_run)
    _check(clean["calls_total"] == 1 and clean["drift_flags"] == [],
           f"a contract-shaped call was flagged as drift: {clean['drift_flags']}")
    _check(clean["steps_count_distribution"] == {"none": 1},
           f"a call without steps must count as none: {clean['steps_count_distribution']}")

    # A run with no probe reports profiles to zero calls and never crashes.
    empty = provider_shapes.record_shapes(work_dir / "empty-run")
    _check(empty["calls_total"] == 0 and empty["drift_flags"] == [],
           f"an empty run must profile clean: {empty}")
    return ["the monitor detects mixed action+steps (01R shape), result-phrase labels, "
            "missing contract fields, conflicting redundancy and unparsable arguments, "
            "counts the steps distribution, leaves contract-shaped calls unflagged, "
            "and writes a non-acceptance shapes.json"]


def test_cassette_replay_is_contract_labeled(work_dir: Path) -> list[str]:
    from . import provider_shapes

    source = (paths.repository_root()
              / "scripts/acceptance/cassettes/example-action-plus-steps.json")
    _check(source.is_file(), f"the example cassette is missing: {source}")
    # The replay writes <cassette>.replay.json next to the cassette, so the copy
    # under test lives in the self-test work dir: the repository stays clean.
    cassette = work_dir / "example-action-plus-steps.json"

    def _fresh_cassette() -> dict:
        return json.loads(source.read_text(encoding="utf-8"))

    cassette.write_bytes(source.read_bytes())
    result = provider_shapes.replay_cassette(cassette)
    _check(result["acceptance"] is False,
           "a cassette replay must never claim acceptance evidence")
    _check(result["purpose"] == "contract-regression",
           f"a cassette replay must be purpose-labeled: {result['purpose']!r}")
    _check(result["matched"] is True,
           f"the example cassette regressed against the judges: {result['verdict']}")
    _check(result["verdict"]["status"] == "passed",
           f"the 01R shape must still judge as the intended click: {result['verdict']}")
    _check(any("delivery-sufficient" in line for line in result["verdict"]["basis"]),
           f"the passing basis must cite its corroborated completion: {result['verdict']['basis']}")
    _check(result["shape_profile"]["mixed_action_and_steps"]["count"] == 1,
           "the replay must profile the cassette's raw arguments shape")

    replay_file = work_dir / "example-action-plus-steps.json.replay.json"
    _check(replay_file.is_file(), "the replay wrote no <cassette>.replay.json")
    on_disk = json.loads(replay_file.read_text(encoding="utf-8"))
    _check(on_disk["acceptance"] is False and on_disk["purpose"] == "contract-regression",
           "the on-disk replay artifact must carry the anti-impersonation header")

    # A wrong expectation is a regression, and a state that no longer
    # corroborates the receipt (the double-click normalization failure) must
    # make the judges fail: the replay re-judges, it does not rubber-stamp.
    conflicting = _fresh_cassette()
    conflicting["state_after"]["clicks"] = 2
    conflicting["state_after"]["events"] = ["right-setting", "right-setting"]
    conflicting["expect"] = {"verdict": "failed", "failure_contains": "clicks changed by 2"}
    _write_json_file(cassette, conflicting)
    double = provider_shapes.replay_cassette(cassette, write=False)
    _check(double["matched"] is True,
           f"a double-clicking state must fail the judges: {double['verdict']}")

    mislabeled = _fresh_cassette()
    mislabeled["expect"]["verdict"] = "failed"
    _write_json_file(cassette, mislabeled)
    mismatch = provider_shapes.replay_cassette(cassette, write=False)
    _check(mismatch["matched"] is False and mismatch["regression"] is True,
           "a cassette whose expectation no longer holds must report a regression")
    return ["the example action+steps cassette replays to a passing judge verdict, "
            "every replay artifact is stamped acceptance=false / purpose=contract-regression "
            "by the replay tool itself, a double-clicking state fails the judges, and a "
            "stale expectation is reported as a regression"]


# ------------------------------------------------- conversation script schema


def _conversation_globals(name: str) -> dict:
    return {
        "name": name,
        "app": "Her.app",
        "fixture_url": paths.FIXTURE_URL,
        "trace_prefix": f"conversation/{name}",
    }


def _two_turn_conversation_script() -> dict:
    """The degenerate case the existing continuity probe can still drive."""
    script = _conversation_globals("progress_then_cancel_degenerate")
    script["turns"] = [
        {"text": "这个任务进行到哪一步了？", "wait_ms": 0, "barge_in": False,
         "expect": {"no_new_action": True}},
        {"text": "取消这个任务", "wait_ms": 900, "barge_in": False,
         "expect": {"tool_call": "task_control"}},
    ]
    return script


def _valid_conversation_scripts() -> list[tuple[str, dict]]:
    single = _conversation_globals("single_utterance")
    single["turns"] = [
        {"text": "帮我把右边的设置按钮点一下", "expect": {"tool_call": "act_on_screen"}},
    ]

    # A barge-in is legal exactly when a previous turn exists to interrupt, and
    # speech expectations may be a list of substrings.
    barge_later = _conversation_globals("correction_after_barge_in")
    barge_later["turns"] = [
        {"text": "帮我把右边的设置按钮点一下", "wait_ms": 0, "barge_in": False,
         "expect": {"tool_call": "act_on_screen"}},
        {"text": "等一下，先别点", "wait_ms": 1200, "barge_in": True,
         "expect": {"no_new_action": True, "speech_not_contains": ["已点击", "已确认"]}},
    ]

    return [
        ("committed example cassette",
         conversation_driver.load_script(conversation_driver.example_script_path())),
        ("single-turn script", single),
        ("two-turn script", _two_turn_conversation_script()),
        ("barge-in on a later turn", barge_later),
    ]


def _invalid_conversation_scripts() -> list[tuple[str, dict, str]]:
    barge_first = _conversation_globals("barge_in_on_the_first_turn")
    barge_first["turns"] = [
        {"text": "等一下，先别点", "wait_ms": 0, "barge_in": True,
         "expect": {"no_new_action": True}},
    ]

    empty_turn = _conversation_globals("silent_turn_with_nothing_to_check")
    empty_turn["turns"] = [
        {"text": "   ", "expect": {"something_else": True}},
    ]

    too_many_turns = _conversation_globals("unbounded_conversation")
    too_many_turns["turns"] = [
        {"text": f"第 {index} 句话", "expect": {"no_new_action": True}}
        for index in range(conversation_driver.MAX_TURNS + 1)
    ]

    missing_keys = _conversation_globals("missing_globals_and_a_negative_wait")
    missing_keys.pop("trace_prefix")
    missing_keys["turns"] = [
        {"text": "取消这个任务", "wait_ms": -5, "expect": {}},
    ]

    unknown_keys = _conversation_globals("unknown_keys")
    unknown_keys["surprise"] = 1
    unknown_keys["turns"] = [
        {"text": "取消这个任务", "surprise_turn": True, "expect": {"tool_call": "task_control"}},
    ]

    long_text = _conversation_globals("overlong_utterance")
    long_text["turns"] = [
        {"text": "取消" * conversation_driver.MAX_TURN_TEXT_CHARS,
         "expect": {"tool_call": "task_control"}},
    ]

    empty_speech_list = _conversation_globals("empty_speech_expectation")
    empty_speech_list["turns"] = [
        {"text": "取消这个任务", "expect": {"speech_contains": []}},
    ]

    return [
        ("barge_in on the first turn", barge_first, "barge_in"),
        ("empty turn text and an unrecognizable expectation", empty_turn, "text"),
        ("more turns than the schema allows", too_many_turns, str(conversation_driver.MAX_TURNS)),
        ("missing global key with a negative wait", missing_keys, "trace_prefix"),
        ("unknown turn/global keys", unknown_keys, "surprise"),
        ("overlong utterance text", long_text, str(conversation_driver.MAX_TURN_TEXT_CHARS)),
        ("empty speech expectation list", empty_speech_list, "speech_contains"),
    ]


def test_conversation_script_schema_and_probe_degradation(work_dir: Path) -> list[str]:
    app_binary = Path("/Applications/Her.app/Contents/MacOS/Her")
    cache_dir = work_dir / "conversation-utterances"
    placeholder = synthesize_placeholder_for_self_tests

    for label, script in _valid_conversation_scripts():
        problems = conversation_driver.validate_script(script)
        _check(problems == [], f"{label} was rejected by validate_script: {problems}")

    for label, script, expected_fragment in _invalid_conversation_scripts():
        problems = conversation_driver.validate_script(script)
        _check(problems, f"{label} was accepted by validate_script")
        _check(any(expected_fragment in problem for problem in problems),
               f"{label}: expected a problem naming {expected_fragment!r}, got {problems}")

    # The committed example must declare what it is: a contract sample, never
    # acceptance evidence, and its barge-in sits on a turn that has a predecessor.
    example = conversation_driver.load_script(conversation_driver.example_script_path())
    _check(example.get("acceptance") is False,
           "the conversation example must be labeled acceptance=false")
    _check(conversation_driver.barge_in_turn_indices(example) == [1],
           f"the example's barge-in turn is wrong: "
           f"{conversation_driver.barge_in_turn_indices(example)}")
    _check(conversation_driver.turn_count(example) <= conversation_driver.MAX_TURNS,
           "the example itself exceeds the schema's turn bound")

    # plan_utterances: one PCM per turn, in script order, through the same
    # synthesis path the runner already uses (the placeholder here: no `say`,
    # deterministic, and explicitly labeled as not real speech).
    plans = conversation_driver.plan_utterances(example, cache_dir, synthesizer=placeholder)
    _check(len(plans) == conversation_driver.turn_count(example),
           f"expected one plan per turn: {len(plans)} plans for "
           f"{conversation_driver.turn_count(example)} turns")
    for index, plan in enumerate(plans):
        _check(plan.text == example["turns"][index]["text"],
               f"turn {index} text drifted from the script: {plan.text!r}")
        _check(plan.pcm_path.is_file() and plan.pcm_path.stat().st_size > 0,
               f"turn {index} produced no PCM: {plan.pcm_path}")
        _check(plan.audio.is_real_speech is False,
               "placeholder PCM must stay labeled as not real speech")
    _check(plans[0].as_tuple() == (plans[0].text, plans[0].pcm_path),
           "the (text, pcm_path) pair projection is wrong")
    _check([plan.barge_in for plan in plans] == [False, True, False, False, False],
           f"barge-in flags did not follow the script: {[p.barge_in for p in plans]}")
    _check([plan.wait_ms for plan in plans] == [0, 1200, 800, 1500, 1000],
           f"wait offsets did not follow the script: {[p.wait_ms for p in plans]}")
    _check(conversation_driver.total_wait_ms(example) == 4500,
           f"total wait is wrong: {conversation_driver.total_wait_ms(example)}")

    # Fail closed: an unusable script never reaches synthesis.
    try:
        conversation_driver.plan_utterances(_invalid_conversation_scripts()[0][1],
                                            cache_dir, synthesizer=placeholder)
    except conversation_driver.ConversationScriptError:
        pass
    else:
        raise SelfTestFailure("plan_utterances synthesized an invalid conversation script")

    # Two turns degrade onto --voice-continuity-probe, and the argument order is
    # the probe's documented progress-then-cancel order: turn 0 first.
    two_turn = _two_turn_conversation_script()
    two_plans = conversation_driver.plan_utterances(two_turn, cache_dir,
                                                    synthesizer=placeholder)
    mapping = conversation_driver.map_conversation_to_probe(two_turn, two_plans)
    _check(mapping.mode == "voice_continuity" and not mapping.requires_new_probe,
           f"a two-turn script must map onto voice_continuity: {mapping.to_dict()}")
    _check(mapping.utterance_pcm_paths == [two_plans[0].pcm_path, two_plans[1].pcm_path],
           "the continuity mapping must keep turn 0 first and turn 1 second")
    attempt_dir = work_dir / "continuity-attempt"
    continuity_argv = build_probe_argv(conversation_driver.to_probe_request(
        mapping, app_binary, attempt_dir))
    _check(continuity_argv == [str(app_binary), "--voice-continuity-probe",
                               str(two_plans[0].pcm_path), str(two_plans[1].pcm_path),
                               str(attempt_dir / "continuity-report.json")],
           f"two-turn conversation mapped onto the wrong continuity argv: {continuity_argv}")
    _check(continuity_argv.index(str(two_plans[0].pcm_path))
           < continuity_argv.index(str(two_plans[1].pcm_path)),
           f"the progress utterance must precede the cancel utterance: {continuity_argv}")

    # One turn degrades onto the single-utterance voice_task probe.
    single = _valid_conversation_scripts()[1][1]
    single_plans = conversation_driver.plan_utterances(single, cache_dir,
                                                       synthesizer=placeholder)
    single_mapping = conversation_driver.map_conversation_to_probe(single, single_plans)
    _check(single_mapping.mode == "voice_task" and not single_mapping.requires_new_probe,
           f"a single-turn script must map onto voice_task: {single_mapping.to_dict()}")
    task_dir = work_dir / "task-attempt"
    task_argv = build_probe_argv(conversation_driver.to_probe_request(
        single_mapping, app_binary, task_dir))
    _check(task_argv == [str(app_binary), "--voice-task-probe", "com.apple.Safari",
                         str(single_plans[0].pcm_path), str(task_dir)],
           f"single-turn conversation mapped onto the wrong voice_task argv: {task_argv}")

    # The barge-in conversation (and any 3+ turn script) is rebuild-gated: it
    # must refuse to degrade rather than drop turns onto a probe that cannot
    # play them back.
    gated = conversation_driver.map_conversation_to_probe(example, plans)
    _check(gated.mode == "unmapped" and gated.requires_new_probe is True,
           f"a barge-in conversation must not map onto an existing probe: {gated.to_dict()}")
    _check(conversation_driver.PROPOSED_CONVERSATION_PROBE_FLAG in gated.proposed_argv_template,
           f"the rebuild-gated mapping must name the probe it needs: "
           f"{gated.proposed_argv_template}")
    _check("barge-in" in gated.reason,
           f"the rebuild-gated reason must name the barge-in: {gated.reason}")
    try:
        conversation_driver.to_probe_request(gated, app_binary, attempt_dir)
    except conversation_driver.ConversationScriptError as error:
        _check("rebuild-gated" in str(error),
               f"the refusal must say rebuild-gated: {error}")
    else:
        raise SelfTestFailure("a barge-in conversation was mapped onto an existing probe")

    three_turns = _conversation_globals("three_turns_without_barge_in")
    three_turns["turns"] = [
        {"text": "帮我把右边的设置按钮点一下", "expect": {"tool_call": "act_on_screen"}},
        {"text": "这个任务进行到哪一步了？", "wait_ms": 700,
         "expect": {"no_new_action": True}},
        {"text": "取消这个任务", "wait_ms": 700,
         "expect": {"tool_call": "task_control"}},
    ]
    three_plans = conversation_driver.plan_utterances(three_turns, cache_dir,
                                                      synthesizer=placeholder)
    three_mapping = conversation_driver.map_conversation_to_probe(three_turns, three_plans)
    _check(three_mapping.requires_new_probe is True,
           f"three turns cannot be driven by the one/two-PCM probes: {three_mapping.to_dict()}")
    _check(three_mapping.utterance_pcm_paths == [plan.pcm_path for plan in three_plans],
           "an unmapped script must still carry every planned PCM, in turn order")

    # The manifest the new probe would consume keeps the whole timeline.
    manifest = conversation_driver.build_conversation_manifest(example, plans)
    _check(manifest["acceptance"] is False and len(manifest["turns"]) == 5,
           f"the conversation manifest is wrong: {sorted(manifest)}")
    _check(manifest["turns"][1]["barge_in"] is True
           and manifest["turns"][1]["pcm_path"] == str(plans[1].pcm_path)
           and manifest["turns"][1]["expect"] == example["turns"][1]["expect"],
           f"the manifest lost the barge-in turn: {manifest['turns'][1]}")
    _check(manifest["turns"][0]["is_real_speech"] is False,
           "placeholder PCM must be reported as not real speech in the manifest")

    return ["the committed conversation example validates and is labeled acceptance=false; "
            "4 legal and 7 illegal scripts are judged by the schema (barge-in on turn 0, "
            "silent/expect-less turn, turn bound, missing global, unknown keys, overlong text, "
            "empty speech list); plan_utterances synthesizes one labeled placeholder PCM per "
            "turn in script order and refuses an invalid script; a one-turn script degrades to "
            "--voice-task-probe; a two-turn script degrades to --voice-continuity-probe with the "
            "progress utterance first and the cancel second; barge-in and 3+ turn scripts are "
            "rebuild-gated and name the probe flag they need"]


# ------------------------------------------------------------------- runner


_TESTS_WITHOUT_WORK_DIR = frozenset({
    test_probe_argument_plumbing,
    test_evidence_schema_validation,
    test_secret_scan_detects_canaries,
    test_scenario_definitions_are_consistent,
})

TESTS = (
    ("scenario definitions are consistent", test_scenario_definitions_are_consistent),
    ("fixture lifecycle and state semantics", test_fixture_lifecycle_and_state_semantics),
    ("fixture port release and clean second start", test_fixture_port_release_and_second_start),
    ("fixture refuses occupied port without killing", test_fixture_refuses_occupied_port_without_killing),
    ("synthetic PCM pipeline", test_synthetic_pcm_pipeline),
    ("probe argument plumbing", test_probe_argument_plumbing),
    ("binary flag detection", test_binary_flag_detection),
    ("probe execution lifecycle", test_probe_execution_lifecycle),
    ("preflight gate blocks and continues", test_preflight_gate_blocks_and_continues),
    ("machine preflight: port occupancy", test_machine_preflight_port_occupancy),
    ("machine preflight: frontmost identity forms",
     test_machine_preflight_frontmost_identity_forms),
    ("machine preflight: binary freshness judgment",
     test_machine_preflight_binary_freshness_judgment),
    ("machine preflight: user Her process record",
     test_machine_preflight_user_her_process_record),
    ("frontmost gate blocks before any call", test_frontmost_gate_blocks_before_any_call),
    ("run mutex serializes concurrent runs", test_run_mutex_serializes_concurrent_runs),
    ("evidence schema validation", test_evidence_schema_validation),
    ("secret scan canaries", test_secret_scan_detects_canaries),
    ("judge: single-step right setting", test_judge_single_step_scenario),
    ("judge: two-step display settings/scale", test_judge_two_step_scenario),
    ("judge: continuity progress/cancel", test_judge_continuity_scenario),
    ("judge: unknown delivery fault", test_judge_unknown_scenario),
    ("exit status honesty for launched instances",
     test_exit_status_honesty_for_launched_instances),
    ("child process discipline", test_child_process_discipline),
    ("freshness gate blocks stale binary", test_freshness_gate_blocks_stale_binary),
    ("dry run full pipeline twice consistent", test_dry_run_full_pipeline_twice_consistent),
    ("interrupted run still writes a report", test_interrupted_run_still_writes_report),
    ("dry run failure injection detected", test_dry_run_failure_injection_is_detected),
    ("dry run artifacts have no secrets", test_dry_run_artifacts_have_no_secrets),
    ("provider shape monitor detects drift", test_provider_shape_monitor_detects_drift),
    ("cassette replay is labeled contract regression", test_cassette_replay_is_contract_labeled),
    ("conversation script schema and probe degradation",
     test_conversation_script_schema_and_probe_degradation),
)


def run_all() -> int:
    """Run every self-test; any failure exits non-zero with its raw evidence."""
    print("Her E2E runner self-tests", flush=True)
    print("=" * 72, flush=True)
    passed = 0
    failed = 0
    with tempfile.TemporaryDirectory(prefix="her-acceptance-selftest-") as temporary:
        work_root = Path(temporary) / "workspace"
        work_root.mkdir()
        for index, (label, test) in enumerate(TESTS):
            test_name = f"{index + 1:02d}-{label.replace(' ', '-').replace(':', '').replace('/', '-')}"
            work_dir = work_root / test_name
            work_dir.mkdir(parents=True, exist_ok=True)
            try:
                details = test() if test in _TESTS_WITHOUT_WORK_DIR else test(work_dir)
            except SelfTestFailure as failure:
                failed += 1
                print(f"FAIL  {label}", flush=True)
                print(f"      {failure}", flush=True)
            except Exception as error:  # noqa: BLE001 - self-tests must never crash silently
                failed += 1
                print(f"ERROR {label}", flush=True)
                print(f"      {type(error).__name__}: {error}", flush=True)
            else:
                passed += 1
                print(f"PASS  {label}", flush=True)
                for detail in details:
                    print(f"      {detail}", flush=True)
    print("=" * 72, flush=True)
    print(f"self-tests: {passed} passed, {failed} failed", flush=True)
    if failed:
        print("Self-test failures are runner bugs: no acceptance evidence may be produced "
              "until they are fixed.", flush=True)
        return 1
    print("App-dependent phases still require the signed DEBUG Her.app, Xcode rebuild, "
          "and the user's Keychain key; they are marked pending-integrator-run in the "
          "evidence package.", flush=True)
    return 0