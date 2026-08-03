#!/usr/bin/env python3
"""Read the immutable v13 baseline from its pinned Git tag."""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
AUTHORITY_TAG = "authority-v13-frozen"
AUTHORITY_COMMIT_OID = "2f65cbf75a671b5826105f8a97440c42b65fdd65"
AUTHORITY_TREE_OID = "316de2b4de28474ed1fbb1ae5793f4e60df21362"

# Historical authority-package identifier only. Tree authority comes from the
# pinned ``authority-v13-frozen`` Git tag, not from this archive digest.
AUTHORITY_ZIP_SHA256 = (
    "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5"
)

OID_RE = re.compile(r"^[0-9a-f]{40}$")


class GitAuthorityError(RuntimeError):
    """The frozen tag cannot be read without ambiguity."""


@dataclass(frozen=True)
class AuthorityIdentity:
    tag: str
    commit_oid: str
    tree_oid: str


def _safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and "\0" not in value
        and not any(ord(character) < 32 for character in value)
        and not path.is_absolute()
        and ".." not in path.parts
        and path.as_posix() == value
    )


def _run_git(root: Path, arguments: list[str]) -> bytes:
    environment = dict(os.environ)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise GitAuthorityError(
            f"git {' '.join(arguments)} failed ({process.returncode}): {stderr}"
        )
    return process.stdout


def _resolve_oid(root: Path, expression: str) -> str:
    try:
        value = _run_git(root, ["rev-parse", "--verify", expression]).decode(
            "ascii"
        ).strip()
    except UnicodeDecodeError as error:
        raise GitAuthorityError(
            f"Git returned a non-ASCII object ID for {expression}"
        ) from error
    if OID_RE.fullmatch(value) is None:
        raise GitAuthorityError(f"Git returned an invalid object ID for {expression}")
    return value


def resolve_authority(root: Path = ROOT) -> AuthorityIdentity:
    """Resolve the tag and fail if either pinned Git object changed."""

    repository = root.resolve()
    tag_ref = f"refs/tags/{AUTHORITY_TAG}"
    commit_oid = _resolve_oid(repository, f"{tag_ref}^{{commit}}")
    tree_oid = _resolve_oid(repository, f"{tag_ref}^{{tree}}")
    if commit_oid != AUTHORITY_COMMIT_OID:
        raise GitAuthorityError(
            f"authority tag commit moved: expected {AUTHORITY_COMMIT_OID}, got {commit_oid}"
        )
    if tree_oid != AUTHORITY_TREE_OID:
        raise GitAuthorityError(
            f"authority tag tree moved: expected {AUTHORITY_TREE_OID}, got {tree_oid}"
        )
    return AuthorityIdentity(AUTHORITY_TAG, commit_oid, tree_oid)


def resolve_authority_commit(root: Path = ROOT) -> str:
    return resolve_authority(root).commit_oid


def resolve_authority_tree(root: Path = ROOT) -> str:
    return resolve_authority(root).tree_oid


def head_commit_oid(root: Path = ROOT) -> str:
    repository = root.resolve()
    return _resolve_oid(repository, "HEAD^{commit}")


def authority_paths(root: Path = ROOT) -> frozenset[str]:
    """Return the exact regular-file path set stored by the frozen tag."""

    repository = root.resolve()
    before = resolve_authority(repository)
    raw = _run_git(
        repository,
        ["ls-tree", "-r", "-z", "--full-tree", before.tree_oid],
    )
    paths: set[str] = set()
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, separator, encoded = record.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise GitAuthorityError("authority tag contains an invalid tree record")
        mode, object_type, _ = fields
        if mode not in {b"100644", b"100755"} or object_type != b"blob":
            raise GitAuthorityError(
                "authority tag path set contains a non-regular entry"
            )
        try:
            relative = encoded.decode("utf-8")
        except UnicodeDecodeError as error:
            raise GitAuthorityError("authority tag contains a non-UTF-8 path") from error
        if not _safe_relative(relative):
            raise GitAuthorityError(f"authority tag contains an unsafe path: {relative!r}")
        if relative in paths:
            raise GitAuthorityError(f"authority tag contains a duplicate path: {relative}")
        paths.add(relative)
    if not paths:
        raise GitAuthorityError("authority tag path set is empty")
    if resolve_authority(repository) != before:
        raise GitAuthorityError("authority tag moved while its path set was read")
    return frozenset(paths)


def authority_file(relative: str, root: Path = ROOT) -> bytes:
    """Read one frozen file through ``git show`` without a worktree copy."""

    if not _safe_relative(relative):
        raise GitAuthorityError(f"unsafe authority path: {relative!r}")
    repository = root.resolve()
    before = resolve_authority(repository)
    content = _run_git(repository, ["show", f"{before.commit_oid}:{relative}"])
    if resolve_authority(repository) != before:
        raise GitAuthorityError("authority tag moved while a member was read")
    return content


def authority_archive(root: Path = ROOT) -> bytes:
    """Return a tar stream produced directly by ``git archive`` for the tag."""

    repository = root.resolve()
    before = resolve_authority(repository)
    archive = _run_git(
        repository,
        ["archive", "--format=tar", before.commit_oid],
    )
    if not archive:
        raise GitAuthorityError("git archive returned an empty authority tree")
    if resolve_authority(repository) != before:
        raise GitAuthorityError("authority tag moved while its archive was read")
    return archive
