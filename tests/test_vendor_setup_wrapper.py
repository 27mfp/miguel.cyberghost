"""Behavioral tests for the vendor's misleading confirmation defaults."""

import importlib.util
import os
import pty
import select
import subprocess
import sys
import time
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location(
    "vendor_setup_wrapper", Path(__file__).resolve().parents[1] / "scripts/setup-vendor-cli.py"
)
wrapper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wrapper)


@pytest.mark.parametrize("prompt", wrapper.ConfirmationDefaults.PROMPTS)
@pytest.mark.parametrize("enter", [b"\r", b"\n"])
def test_enter_accepts_only_a_known_confirmation(prompt, enter):
    state = wrapper.ConfirmationDefaults()
    assert state.observe_output(prompt) == prompt
    assert state.translate_input(enter) == b"y" + enter
    assert not state.confirmation


def test_fragmented_prompt_is_recognized_once():
    state = wrapper.ConfirmationDefaults()
    prompt = state.PROMPTS[0]
    for byte in prompt:
        state.observe_output(bytes([byte]))
    assert state.translate_input(b"\r") == b"y\r"
    state.observe_output(b"Enter CyberGhost password: ")
    assert state.translate_input(b"\r") == b"\r"


@pytest.mark.parametrize("answer", [b"n\r", b"N\n", b"y\r", b"Y\n", b" \r"])
def test_explicit_answers_are_never_overridden(answer):
    state = wrapper.ConfirmationDefaults()
    state.observe_output(state.PROMPTS[0])
    assert state.translate_input(answer) == answer


def test_typed_answer_across_reads_and_erased_answer():
    state = wrapper.ConfirmationDefaults()
    state.observe_output(state.PROMPTS[0])
    assert state.translate_input(b"n") == b"n"
    assert state.translate_input(b"\x7f") == b"\x7f"
    assert state.translate_input(b"\r") == b"y\r"


def test_credentials_are_not_transformed_or_retained():
    state = wrapper.ConfirmationDefaults()
    state.observe_output(b"[sudo] password: ")
    assert state.translate_input(b"example-password\r") == b"example-password\r"
    assert not state.answer
    state.observe_output(state.PROMPTS[0])
    assert state.translate_input(b"y\rnext-input\r") == b"y\rnext-input\r"
    assert not state.answer


def test_second_confirmation_is_independent():
    state = wrapper.ConfirmationDefaults()
    for prompt in state.PROMPTS:
        state.observe_output(prompt)
        assert state.translate_input(b"\r") == b"y\r"


def test_real_terminal_defaults_and_hidden_password():
    fake_vendor = (
        "import getpass; "
        f"print('first=' + input({wrapper.ConfirmationDefaults.PROMPTS[0].decode()!r}), flush=True); "
        f"print('second=' + input({wrapper.ConfirmationDefaults.PROMPTS[1].decode()!r}), flush=True); "
        "password=getpass.getpass('Password: '); "
        "print('password-ok' if password == 'fake-terminal-secret' else 'password-bad', flush=True)"
    )
    driver = (
        "import importlib.util, os, pty, sys; "
        f"s=importlib.util.spec_from_file_location('w', {str(SPEC.origin)!r}); "
        "w=importlib.util.module_from_spec(s); s.loader.exec_module(w); d=w.ConfirmationDefaults(); "
        f"status=pty.spawn([sys.executable, '-c', {fake_vendor!r}], "
        "master_read=lambda fd:d.observe_output(os.read(fd,1024)), "
        "stdin_read=lambda fd:d.translate_input(os.read(fd,1024))); "
        "sys.exit(w.exit_code(status))"
    )
    master, slave = pty.openpty()
    process = subprocess.Popen(  # noqa: S603 - fixed synthetic terminal test, never launches sudo/vendor CLI
        [sys.executable, "-c", driver], stdin=slave, stdout=slave, stderr=slave, start_new_session=True
    )
    transcript = bytearray()

    def read_until(marker):
        deadline = time.monotonic() + 5
        while marker not in transcript:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"Missing terminal output: {marker!r}"
            if select.select([master], [], [], remaining)[0]:
                data = os.read(master, 4096)
                assert data, "Terminal closed early"
                transcript.extend(data)

    try:
        read_until(wrapper.ConfirmationDefaults.PROMPTS[0])
        os.write(master, b"\r")
        read_until(b"first=y")
        read_until(wrapper.ConfirmationDefaults.PROMPTS[1])
        os.write(master, b"n\r")
        read_until(b"second=n")
        read_until(b"Password: ")
        os.write(master, b"fake-terminal-secret\r")
        read_until(b"password-ok")
        code = process.wait(timeout=5)
        while select.select([master], [], [], 0)[0]:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            transcript.extend(data)
        assert code == 0, transcript.decode(errors="replace")
        assert b"fake-terminal-secret" not in transcript
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def test_unknown_confirmation_is_not_changed():
    state = wrapper.ConfirmationDefaults()
    state.observe_output(b"Remove all accounts? [Y/n]: ")
    assert state.translate_input(b"\r") == b"\r"
