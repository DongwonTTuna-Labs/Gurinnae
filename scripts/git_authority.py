#!/usr/bin/env python3
"""Read the immutable v13 baseline from Git or pinned archive metadata."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
AUTHORITY_TAG = "authority-v13-frozen"
AUTHORITY_COMMIT_OID = "2f65cbf75a671b5826105f8a97440c42b65fdd65"
AUTHORITY_TREE_OID = "316de2b4de28474ed1fbb1ae5793f4e60df21362"
AUTHORITY_MANIFEST_FILE = "AUTHORITY-v13-frozen.manifest.json"
AUTHORITY_MANIFEST_SHA256 = "e9de087af8f917c1fa49211a022f89e4c7e8a02487098a9b3012d839e20b9a79"

# Historical authority-package identifier only. Tree authority comes from the
# pinned Git tag or the separately pinned archive-only manifest.
AUTHORITY_ZIP_SHA256 = "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5"

AUTHORITY_MANIFEST_SCHEMA_VERSION = 1
AUTHORITY_PATH_COUNT = 4_347
AUTHORITY_EMBEDDED_PATH_COUNT = 62
AUTHORITY_EMBEDDED_BYTES = 451_013
BASE_ACCEPTANCE_LOCK = "tests/acceptance/base-v13.lock.yaml"
MIGRATION_PREFIX = "specs/database/migrations/"
OID_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MANIFEST_KEYS = frozenset({
    "schema_version", "tag", "commit_oid", "tree_oid", "authority_paths", "embedded_files"})
PATH_KEYS = frozenset({"path", "mode", "blob_oid"})
EMBEDDED_KEYS = frozenset({"path", "content_base64"})


class GitAuthorityError(RuntimeError):
    """The frozen authority cannot be read without ambiguity."""


@dataclass(frozen=True)
class AuthorityIdentity:
    tag: str
    commit_oid: str
    tree_oid: str


@dataclass(frozen=True)
class AuthorityPath:
    path: str
    mode: str
    blob_oid: str


@dataclass(frozen=True)
class EmbeddedAuthorityFile:
    path: str
    content: bytes


@dataclass(frozen=True)
class AuthorityManifest:
    identity: AuthorityIdentity
    authority_paths: tuple[AuthorityPath, ...]
    embedded_files: tuple[EmbeddedAuthorityFile, ...]


class _UniqueYamlLoader(yaml.SafeLoader):
    """Reject duplicate keys in the frozen acceptance lock."""


def _unique_yaml_mapping(
    loader: _UniqueYamlLoader,
    node: yaml.nodes.MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in result
        except TypeError as error:
            raise GitAuthorityError(f"unhashable YAML key: {key!r}") from error
        if duplicate:
            raise GitAuthorityError(f"duplicate YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


_UniqueYamlLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_yaml_mapping
)


def _safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and path.parts
        and "\\" not in value
        and "\0" not in value
        and not any(ord(character) < 32 for character in value)
        and not path.is_absolute()
        and "." not in path.parts
        and ".." not in path.parts
        and path.as_posix() == value
    )


def _git_entry_exists(root: Path) -> bool:
    return os.path.lexists(root / ".git")


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
        value = _run_git(root, ["rev-parse", "--verify", expression]).decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise GitAuthorityError(
            f"Git returned a non-ASCII object ID for {expression}"
        ) from error
    if OID_RE.fullmatch(value) is None:
        raise GitAuthorityError(f"Git returned an invalid object ID for {expression}")
    return value


def _resolve_git_authority(root: Path) -> AuthorityIdentity:
    tag_ref = f"refs/tags/{AUTHORITY_TAG}"
    commit_oid = _resolve_oid(root, f"{tag_ref}^{{commit}}")
    tree_oid = _resolve_oid(root, f"{tag_ref}^{{tree}}")
    if commit_oid != AUTHORITY_COMMIT_OID:
        raise GitAuthorityError(
            f"authority tag commit moved: expected {AUTHORITY_COMMIT_OID}, "
            f"got {commit_oid}"
        )
    if tree_oid != AUTHORITY_TREE_OID:
        raise GitAuthorityError(
            f"authority tag tree moved: expected {AUTHORITY_TREE_OID}, got {tree_oid}"
        )
    return AuthorityIdentity(AUTHORITY_TAG, commit_oid, tree_oid)


def _git_authority_failure(root: Path, error: GitAuthorityError) -> GitAuthorityError:
    return GitAuthorityError(
        f"Git authority is unavailable and archive fallback is disabled because "
        f"{root / '.git'} exists: {error}. Restore this exact tag with "
        f"`git fetch origin tag {AUTHORITY_TAG}`. CI checkout must fetch tags "
        "(for example, `git fetch --tags --force`); if origin lacks the tag, the "
        f"repository supervisor must run `git push origin {AUTHORITY_TAG}`."
    )


def _read_git_paths(root: Path, tree_oid: str) -> tuple[AuthorityPath, ...]:
    raw = _run_git(root, ["ls-tree", "-r", "-z", "--full-tree", tree_oid])
    entries: list[AuthorityPath] = []
    previous = ""
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, separator, encoded = record.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3:
            raise GitAuthorityError("authority tag contains an invalid tree record")
        encoded_mode, object_type, encoded_oid = fields
        if encoded_mode not in {b"100644", b"100755"} or object_type != b"blob":
            raise GitAuthorityError(
                "authority tag path set contains a non-regular entry"
            )
        try:
            mode = encoded_mode.decode("ascii")
            blob_oid = encoded_oid.decode("ascii")
            relative = encoded.decode("utf-8")
        except UnicodeDecodeError as error:
            raise GitAuthorityError(
                "authority tag contains non-UTF-8 tree metadata"
            ) from error
        if OID_RE.fullmatch(blob_oid) is None:
            raise GitAuthorityError(f"invalid authority blob OID: {blob_oid!r}")
        if not _safe_relative(relative):
            raise GitAuthorityError(f"authority tag contains an unsafe path: {relative!r}")
        if relative <= previous:
            raise GitAuthorityError(
                f"authority tag paths are duplicate or unsorted: {relative}"
            )
        entries.append(AuthorityPath(relative, mode, blob_oid))
        previous = relative
    if len(entries) != AUTHORITY_PATH_COUNT:
        raise GitAuthorityError(
            f"authority tag regular-file count differs: "
            f"{len(entries)} != {AUTHORITY_PATH_COUNT}"
        )
    return tuple(entries)


def _git_blob_oid(content: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()


def _read_git_blob(root: Path, entry: AuthorityPath) -> bytes:
    content = _run_git(root, ["cat-file", "blob", entry.blob_oid])
    actual_oid = _git_blob_oid(content)
    if actual_oid != entry.blob_oid:
        raise GitAuthorityError(
            f"Git blob bytes differ for {entry.path}: {actual_oid} != {entry.blob_oid}"
        )
    return content


def _exact_keys(value: object, expected: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GitAuthorityError(f"{label} must be a JSON object")
    actual = set(value)
    if actual != expected:
        raise GitAuthorityError(
            f"{label} keys differ: missing={sorted(expected - actual)} "
            f"extra={sorted(actual - expected)}"
        )
    return value


def _require_string(mapping: dict[str, Any], key: str, label: str) -> str:
    value = mapping[key]
    if not isinstance(value, str):
        raise GitAuthorityError(f"{label}.{key} must be a string")
    return value


def _acceptance_expectations(lock_content: bytes) -> dict[str, tuple[str, int | None]]:
    try:
        lock = yaml.load(lock_content, Loader=_UniqueYamlLoader)
    except (UnicodeDecodeError, yaml.YAMLError) as error:
        raise GitAuthorityError(f"cannot parse frozen base acceptance lock: {error}") from error
    if not isinstance(lock, dict):
        raise GitAuthorityError("frozen base acceptance lock must be a mapping")
    features = lock.get("features")
    if lock.get("feature_count") != 35 or not isinstance(features, list):
        raise GitAuthorityError("frozen base acceptance lock feature count differs")
    if len(features) != 35:
        raise GitAuthorityError(
            f"frozen base acceptance feature rows differ: {len(features)} != 35"
        )

    expectations: dict[str, tuple[str, int | None]] = {}
    for key in ("catalog", "executable_mapping"):
        row = lock.get(key)
        if not isinstance(row, dict) or set(row) != {"path", "sha256"}:
            raise GitAuthorityError(f"frozen base acceptance {key} row is invalid")
        _add_acceptance_expectation(expectations, row, None, key)
    for index, row in enumerate(features):
        if not isinstance(row, dict) or set(row) != {"path", "sha256", "size"}:
            raise GitAuthorityError(f"frozen base acceptance feature row {index} is invalid")
        size = row.get("size")
        if type(size) is not int or size < 0:
            raise GitAuthorityError(f"frozen base acceptance feature size {index} is invalid")
        _add_acceptance_expectation(expectations, row, size, f"feature row {index}")
    if len(expectations) != 37:
        raise GitAuthorityError("frozen base acceptance paths are not unique")
    return expectations


def _add_acceptance_expectation(
    expectations: dict[str, tuple[str, int | None]],
    row: dict[Any, Any],
    size: int | None,
    label: str,
) -> None:
    relative = row.get("path")
    digest = row.get("sha256")
    if not isinstance(relative, str) or not _safe_relative(relative):
        raise GitAuthorityError(f"frozen base acceptance {label} path is unsafe")
    if PurePosixPath(relative).parent != PurePosixPath("."):
        raise GitAuthorityError(f"frozen base acceptance {label} path is not a filename")
    if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
        raise GitAuthorityError(f"frozen base acceptance {label} digest is invalid")
    path = f"tests/acceptance/{relative}"
    if path in expectations:
        raise GitAuthorityError(f"duplicate frozen base acceptance path: {path}")
    expectations[path] = (digest, size)


def _embedded_paths(
    indexed: dict[str, AuthorityPath],
    contents: dict[str, bytes],
) -> frozenset[str]:
    lock_content = contents.get(BASE_ACCEPTANCE_LOCK)
    if lock_content is None:
        raise GitAuthorityError(f"embedded authority is missing {BASE_ACCEPTANCE_LOCK}")
    expectations = _acceptance_expectations(lock_content)
    expected = {BASE_ACCEPTANCE_LOCK, *expectations}
    expected.update(path for path in indexed if path.startswith(MIGRATION_PREFIX))
    if len(expected) != AUTHORITY_EMBEDDED_PATH_COUNT:
        raise GitAuthorityError(
            f"embedded authority path count differs: "
            f"{len(expected)} != {AUTHORITY_EMBEDDED_PATH_COUNT}"
        )
    for path, (digest, size) in expectations.items():
        content = contents.get(path)
        if content is None:
            raise GitAuthorityError(f"embedded authority is missing {path}")
        if hashlib.sha256(content).hexdigest() != digest:
            raise GitAuthorityError(f"frozen base acceptance digest differs: {path}")
        if size is not None and len(content) != size:
            raise GitAuthorityError(f"frozen base acceptance size differs: {path}")
    return frozenset(expected)


def _canonical_json(document: dict[str, Any]) -> bytes:
    rendered = json.dumps(
        document,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    )
    return rendered.encode("utf-8") + b"\n"


def _render_authority_manifest_unpinned(root: Path) -> bytes:
    if not _git_entry_exists(root):
        raise GitAuthorityError(
            f"authority manifest generation requires the exact Git root: {root / '.git'}"
        )
    try:
        before = _resolve_git_authority(root)
        paths = _read_git_paths(root, before.tree_oid)
        indexed = {entry.path: entry for entry in paths}
        lock_entry = indexed.get(BASE_ACCEPTANCE_LOCK)
        if lock_entry is None:
            raise GitAuthorityError(f"authority tag is missing {BASE_ACCEPTANCE_LOCK}")
        contents = {BASE_ACCEPTANCE_LOCK: _read_git_blob(root, lock_entry)}
        expectations = _acceptance_expectations(contents[BASE_ACCEPTANCE_LOCK])
        selected = {BASE_ACCEPTANCE_LOCK, *expectations}
        selected.update(path for path in indexed if path.startswith(MIGRATION_PREFIX))
        for path in sorted(selected - {BASE_ACCEPTANCE_LOCK}):
            entry = indexed.get(path)
            if entry is None:
                raise GitAuthorityError(f"authority tag is missing embedded path: {path}")
            contents[path] = _read_git_blob(root, entry)
        expected = _embedded_paths(indexed, contents)
        if set(contents) != expected:
            raise GitAuthorityError("authority generator selected the wrong embedded path set")
        if sum(len(content) for content in contents.values()) != AUTHORITY_EMBEDDED_BYTES:
            raise GitAuthorityError("authority generator embedded byte count differs")
        if _resolve_git_authority(root) != before:
            raise GitAuthorityError("authority tag moved while its manifest was rendered")
    except GitAuthorityError as error:
        raise _git_authority_failure(root, error) from error

    document: dict[str, Any] = {
        "schema_version": AUTHORITY_MANIFEST_SCHEMA_VERSION,
        "tag": before.tag,
        "commit_oid": before.commit_oid,
        "tree_oid": before.tree_oid,
        "authority_paths": [
            {"path": entry.path, "mode": entry.mode, "blob_oid": entry.blob_oid}
            for entry in paths
        ],
        "embedded_files": [
            {
                "path": path,
                "content_base64": base64.b64encode(contents[path]).decode("ascii"),
            }
            for path in sorted(contents)
        ],
    }
    return _canonical_json(document)


def render_authority_manifest(root: Path = ROOT) -> bytes:
    """Render the canonical manifest from Git and require its hardcoded pin."""
    repository = root.resolve()
    raw = _render_authority_manifest_unpinned(repository)
    digest = hashlib.sha256(raw).hexdigest()
    if digest != AUTHORITY_MANIFEST_SHA256:
        raise GitAuthorityError(
            f"canonical authority manifest SHA-256 differs: "
            f"{digest} != {AUTHORITY_MANIFEST_SHA256}"
        )
    return raw


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise GitAuthorityError(f"duplicate authority manifest JSON key: {key!r}")
        result[key] = value
    return result


def _decode_embedded(encoded: str, path: str) -> bytes:
    try:
        ascii_payload = encoded.encode("ascii")
        content = base64.b64decode(ascii_payload, validate=True)
    except (UnicodeEncodeError, binascii.Error, ValueError) as error:
        raise GitAuthorityError(f"invalid base64 authority payload: {path}") from error
    if base64.b64encode(content) != ascii_payload:
        raise GitAuthorityError(f"non-canonical base64 authority payload: {path}")
    return content


def _verify_manifest_digest(raw: bytes) -> None:
    digest = hashlib.sha256(raw).hexdigest()
    if digest != AUTHORITY_MANIFEST_SHA256:
        raise GitAuthorityError(
            f"archive authority manifest SHA-256 differs: "
            f"{digest} != {AUTHORITY_MANIFEST_SHA256}"
        )


def _parse_authority_manifest(raw: bytes) -> AuthorityManifest:
    _verify_manifest_digest(raw)
    try:
        document = json.loads(raw, object_pairs_hook=_unique_json_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GitAuthorityError(f"invalid authority manifest JSON: {error}") from error
    mapping = _exact_keys(document, MANIFEST_KEYS, "authority manifest")
    if type(mapping["schema_version"]) is not int or mapping["schema_version"] != 1:
        raise GitAuthorityError("authority manifest schema version differs")
    tag = _require_string(mapping, "tag", "authority manifest")
    commit_oid = _require_string(mapping, "commit_oid", "authority manifest")
    tree_oid = _require_string(mapping, "tree_oid", "authority manifest")
    identity = AuthorityIdentity(tag, commit_oid, tree_oid)
    expected_identity = AuthorityIdentity(
        AUTHORITY_TAG, AUTHORITY_COMMIT_OID, AUTHORITY_TREE_OID
    )
    if identity != expected_identity:
        raise GitAuthorityError("authority manifest identity differs from its pins")

    raw_paths = mapping["authority_paths"]
    if not isinstance(raw_paths, list) or len(raw_paths) != AUTHORITY_PATH_COUNT:
        raise GitAuthorityError("authority manifest path count differs")
    paths: list[AuthorityPath] = []
    previous = ""
    for index, value in enumerate(raw_paths):
        row = _exact_keys(value, PATH_KEYS, f"authority_paths[{index}]")
        path = _require_string(row, "path", f"authority_paths[{index}]")
        mode = _require_string(row, "mode", f"authority_paths[{index}]")
        blob_oid = _require_string(row, "blob_oid", f"authority_paths[{index}]")
        if not _safe_relative(path) or path <= previous:
            raise GitAuthorityError(f"unsafe, duplicate, or unsorted authority path: {path!r}")
        if mode not in {"100644", "100755"}:
            raise GitAuthorityError(f"invalid authority path mode: {path}")
        if OID_RE.fullmatch(blob_oid) is None:
            raise GitAuthorityError(f"invalid authority path blob OID: {path}")
        paths.append(AuthorityPath(path, mode, blob_oid))
        previous = path
    indexed = {entry.path: entry for entry in paths}

    raw_embedded = mapping["embedded_files"]
    if not isinstance(raw_embedded, list) or len(raw_embedded) != AUTHORITY_EMBEDDED_PATH_COUNT:
        raise GitAuthorityError("authority manifest embedded path count differs")
    embedded: list[EmbeddedAuthorityFile] = []
    contents: dict[str, bytes] = {}
    previous = ""
    for index, value in enumerate(raw_embedded):
        row = _exact_keys(value, EMBEDDED_KEYS, f"embedded_files[{index}]")
        path = _require_string(row, "path", f"embedded_files[{index}]")
        encoded = _require_string(row, "content_base64", f"embedded_files[{index}]")
        if not _safe_relative(path) or path <= previous:
            raise GitAuthorityError(f"unsafe, duplicate, or unsorted embedded path: {path!r}")
        entry = indexed.get(path)
        if entry is None:
            raise GitAuthorityError(f"embedded path is absent from authority index: {path}")
        content = _decode_embedded(encoded, path)
        if _git_blob_oid(content) != entry.blob_oid:
            raise GitAuthorityError(f"embedded Git blob OID differs: {path}")
        embedded.append(EmbeddedAuthorityFile(path, content))
        contents[path] = content
        previous = path
    if sum(len(content) for content in contents.values()) != AUTHORITY_EMBEDDED_BYTES:
        raise GitAuthorityError("authority manifest embedded byte count differs")
    if set(contents) != _embedded_paths(indexed, contents):
        raise GitAuthorityError("authority manifest embedded path set differs")
    if raw != _canonical_json(mapping):
        raise GitAuthorityError("authority manifest JSON is not canonical")
    return AuthorityManifest(identity, tuple(paths), tuple(embedded))


def _load_authority_manifest(root: Path) -> AuthorityManifest:
    path = root / AUTHORITY_MANIFEST_FILE
    if path.is_symlink() or not path.is_file():
        raise GitAuthorityError(
            f"archive authority manifest is missing or unsafe: {path}; regenerate it "
            f"with `make source-archive` from a checkout with pinned tag {AUTHORITY_TAG}")
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise GitAuthorityError(f"cannot read archive authority manifest: {error}") from error
    try:
        return _parse_authority_manifest(raw)
    except GitAuthorityError as error:
        raise GitAuthorityError(
            f"{error}; regenerate the source archive with `make source-archive` "
            f"from a checkout with pinned tag {AUTHORITY_TAG}"
        ) from error


def resolve_authority(root: Path = ROOT) -> AuthorityIdentity:
    """Resolve Git first; use pinned metadata only at an exact gitless root."""
    repository = root.resolve()
    if not _git_entry_exists(repository):
        return _load_authority_manifest(repository).identity
    try:
        return _resolve_git_authority(repository)
    except GitAuthorityError as error:
        raise _git_authority_failure(repository, error) from error


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
    if not _git_entry_exists(repository):
        manifest = _load_authority_manifest(repository)
        return frozenset(entry.path for entry in manifest.authority_paths)
    try:
        before = _resolve_git_authority(repository)
        paths = _read_git_paths(repository, before.tree_oid)
        if _resolve_git_authority(repository) != before:
            raise GitAuthorityError("authority tag moved while its path set was read")
    except GitAuthorityError as error:
        raise _git_authority_failure(repository, error) from error
    return frozenset(entry.path for entry in paths)


def authority_file(relative: str, root: Path = ROOT) -> bytes:
    """Read one frozen file from Git or the exact embedded fallback set."""
    if not _safe_relative(relative):
        raise GitAuthorityError(f"unsafe authority path: {relative!r}")
    repository = root.resolve()
    if not _git_entry_exists(repository):
        manifest = _load_authority_manifest(repository)
        embedded = {entry.path: entry.content for entry in manifest.embedded_files}
        try:
            return embedded[relative]
        except KeyError as error:
            raise GitAuthorityError(
                f"archive authority fallback does not embed path: {relative}"
            ) from error
    try:
        before = _resolve_git_authority(repository)
        content = _run_git(repository, ["show", f"{before.commit_oid}:{relative}"])
        if _resolve_git_authority(repository) != before:
            raise GitAuthorityError("authority tag moved while a member was read")
    except GitAuthorityError as error:
        raise _git_authority_failure(repository, error) from error
    return content


def authority_archive(root: Path = ROOT) -> bytes:
    """Return a Git-produced tar stream; archive fallback cannot synthesize it."""
    repository = root.resolve()
    if not _git_entry_exists(repository):
        raise GitAuthorityError(
            "authority_archive is unsupported for archive manifest fallback; "
            "a real pinned Git tag is required"
        )
    try:
        before = _resolve_git_authority(repository)
        archive = _run_git(
            repository,
            ["archive", "--format=tar", before.commit_oid],
        )
        if not archive:
            raise GitAuthorityError("git archive returned an empty authority tree")
        if _resolve_git_authority(repository) != before:
            raise GitAuthorityError("authority tag moved while its archive was read")
    except GitAuthorityError as error:
        raise _git_authority_failure(repository, error) from error
    return archive
