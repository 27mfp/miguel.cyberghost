"""Suite-wide isolation: tests must never read the developer's real account."""

import pwd

import pytest


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    # The runner locates ~/.cyberghost through pwd (not $HOME), so redirect
    # that lookup for every runner instance the test modules load.
    real = pwd.getpwuid

    def fake(uid):
        entry = real(uid)
        return pwd.struct_passwd((entry.pw_name, "x", entry.pw_uid, entry.pw_gid, "", str(tmp_path), "/bin/sh"))

    monkeypatch.setattr(pwd, "getpwuid", fake)
    monkeypatch.delenv("CYBERGHOST_CONFIG", raising=False)
    return tmp_path
