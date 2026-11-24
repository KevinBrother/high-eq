#!/usr/bin/env python3
"""Replay the T33 owner mutations from the repository root.

Run with: python3 -B docs/compliance/replay_t33_owner_mutations.py
Add --review or --review2 for the review regressions. Each mutation is
supplied to the same targeted test via its source reader in a fresh process.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from os.path import commonprefix
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROFILE = Path("server/internal/profile")
TARGET = (
    "docs.compliance.test_t33_contract.ProfileEvidenceContract."
    "test_profile_inference_revalidates_exact_consents_and_fails_closed"
)
RESULT_SITE = (
    "stored.contactsConsent != reserved.contactsConsent {\n\t\t\tif e = "
    "invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner)"
)
ATTEMPT_SITE = (
    'got.state != "processing" {\n\t\t'
    "return true, invalidateInference(ctx, tx, u, contact, request, got.owner)"
)
SQL_AND_ARGS = "\n\t\t  and owner_id is not distinct from $4::uuid`, u, request, contact, owner)"
RESULT_GUARD = (
    "\t\tif !stored.owner.Valid || stored.owner.UUID != reserved.owner || stored.expired {\n"
    "\t\t\tstale = true\n\t\t\treturn nil\n\t\t}\n"
)
ATTEMPT_GUARD = (
    "\tif !got.owner.Valid || got.owner.UUID != owner || got.expired {\n"
    "\t\treturn true, nil\n\t}\n"
)
CLAIM_OWNER = "owner := uuid.New()\n\ttag, e := tx.Exec"
INVALIDATE_EXEC = (
    "func invalidateInference(ctx context.Context, tx pgx.Tx, u, contact, request uuid.UUID, owner uuid.NullUUID) error {\n"
    "\t_, e := tx.Exec"
)
INVALIDATED_CASE = 'case "invalidated":\n\t\treturn inferenceReservation{}, membership.ErrConflict'
AUTHORIZE_BINDING = (
    "\tcall.Authorize = s.inferenceAuthorizer(session, u, id, in.RequestId, "
    "reserved.chatConsent, reserved.contactsConsent, digest, reserved.owner)\n"
)

RUN_OVERLAY = """
import importlib
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

_, target, filename = sys.argv
module = importlib.import_module(target.rsplit(".", 2)[0])
original_read = module.read
source = sys.stdin.read()

def read(path):
    if Path(path) == Path(filename):
        return source
    return original_read(path)

with patch.object(module, "read", read):
    unittest.main(module=None, argv=["unittest", "-v", target])
"""


@dataclass(frozen=True)
class Mutation:
    description: str
    file: str
    original: str
    replacement: str
    assertion: str
    extra: tuple[str, str] | None = None


MUTATIONS = (
    Mutation(
        "Infer, current row mismatch path: omit stored.owner",
        "infer.go",
        RESULT_SITE,
        RESULT_SITE.removesuffix(", stored.owner)") + ")",
        "invalidateInference arguments must be",
    ),
    Mutation(
        "Infer, current row mismatch path: pass in.RequestId as owner",
        "infer.go",
        RESULT_SITE,
        RESULT_SITE.removesuffix("stored.owner)") + "in.RequestId)",
        "invalidateInference arguments must be",
    ),
    Mutation(
        "checkInferenceAttemptTx, current row mismatch path: pass request as owner",
        "inference_request.go",
        ATTEMPT_SITE,
        ATTEMPT_SITE.removesuffix("got.owner)") + "request)",
        "invalidateInference arguments must be",
    ),
    Mutation(
        "invalidateInference: bind owner_id=$4 to request",
        "inference_request.go",
        SQL_AND_ARGS,
        SQL_AND_ARGS.replace(", owner)", ", request)"),
        "invalidateInference: SQL $4 must bind owner",
    ),
    Mutation(
        "invalidateInference: remove the owner predicate and its binding",
        "inference_request.go",
        SQL_AND_ARGS,
        "`, u, request, contact)",
        "invalidateInference UPDATE must fence the processing row by owner",
    ),
    Mutation(
        "invalidateInference: invert owner equality",
        "inference_request.go",
        SQL_AND_ARGS,
        SQL_AND_ARGS.replace("is not distinct from", "is distinct from"),
        "invalidateInference UPDATE must fence the processing row by owner",
    ),
    Mutation(
        "Infer: remove the result owner mismatch comparison",
        "infer.go",
        " || stored.owner.UUID != reserved.owner",
        "",
        "result path must reject a superseded or expired owner",
    ),
    Mutation(
        "reserveInference: return invalidated rows as successful reuses",
        "inference_request.go",
        INVALIDATED_CASE,
        'case "invalidated":\n\t\treturn got, nil',
        "invalidated reservations must return a conflict",
    ),
)

REVIEW_MUTATIONS = (
    Mutation(
        "Infer: overwrite the current row before invalidating",
        "infer.go",
        RESULT_SITE,
        RESULT_SITE.replace("if e = ", "stored = inferenceRecord{}\n\t\t\tif e = "),
        "stored must keep its current row binding",
    ),
    Mutation(
        "checkInferenceAttemptTx: overwrite owner before a later selector target",
        "inference_request.go",
        ATTEMPT_SITE,
        ATTEMPT_SITE.replace(
            "return true, invalidateInference",
            'owner, got.state = request, "processing"\n\t\treturn true, invalidateInference',
        ),
        "owner must keep its enclosing binding",
    ),
    Mutation(
        "invalidateInference: overwrite the request parameter before tx.Exec",
        "inference_request.go",
        INVALIDATE_EXEC,
        INVALIDATE_EXEC.replace("\t_, e", "\trequest = contact\n\t_, e"),
        "request must keep its enclosing binding",
    ),
    Mutation(
        "claimInference: initialize the owner from request instead of uuid.New",
        "inference_request.go",
        CLAIM_OWNER,
        CLAIM_OWNER.replace("uuid.New()", "request"),
        "owner must be initialized by uuid.New()",
    ),
    Mutation(
        "claimInference: overwrite the freshly generated owner before tx.Exec",
        "inference_request.go",
        CLAIM_OWNER,
        CLAIM_OWNER.replace("\ttag, e", "\towner = request\n\ttag, e"),
        "owner must keep its uuid.New() binding",
    ),
    Mutation(
        "Infer: delete one invalidation call and its error branch",
        "infer.go",
        RESULT_SITE + "; e != nil {\n\t\t\t\treturn e\n\t\t\t}\n",
        RESULT_SITE.split("\n", 1)[0] + "\n",
        "invalidateInference calls must be exactly",
    ),
    Mutation(
        "checkInferenceAttemptTx: return without invalidating one branch",
        "inference_request.go",
        ATTEMPT_SITE,
        ATTEMPT_SITE.replace("invalidateInference(ctx, tx, u, contact, request, got.owner)", "nil"),
        "invalidateInference calls must be exactly",
    ),
    Mutation(
        "Infer: turn the result owner guard into a block comment",
        "infer.go",
        RESULT_GUARD,
        "\t\t/*\n" + RESULT_GUARD + "\t\t*/\n",
        "result path must reject a superseded or expired owner",
    ),
    Mutation(
        "checkInferenceAttemptTx: turn the attempt owner guard into a block comment",
        "inference_request.go",
        ATTEMPT_GUARD,
        "\t\t/*\n" + ATTEMPT_GUARD + "\t\t*/\n",
        "attempt path must reject a superseded or expired owner",
    ),
    Mutation(
        "invalidateInference: compare against the uppercase SQL state literal",
        "inference_request.go",
        "and state='processing'" + SQL_AND_ARGS,
        "and state='PROCESSING'" + SQL_AND_ARGS,
        "invalidateInference UPDATE must fence the processing row by owner",
    ),
    Mutation(
        "Infer: use a package-scope alias for one direct call",
        "infer.go",
        RESULT_SITE,
        RESULT_SITE.replace("invalidateInference(", "aliasInvalidateInference("),
        "invalidateInference calls must be exactly",
        extra=("var ErrMaterial = ", "var aliasInvalidateInference = invalidateInference\n\nvar ErrMaterial = "),
    ),
)

SECOND_REVIEW_MUTATIONS = (
    Mutation(
        "reserveInference: comment out the conflict case and actively reuse invalidated rows",
        "inference_request.go",
        INVALIDATED_CASE,
        "/* " + INVALIDATED_CASE + ' */\n\tcase "invalidated":\n\t\treturn got, nil',
        "invalidated reservations must return a conflict",
    ),
    Mutation(
        "Authorize: leave the correct binding in a comment and pass in.RequestId as owner",
        "infer.go",
        AUTHORIZE_BINDING,
        "\t/*\n" + AUTHORIZE_BINDING + "\t*/\n"
        + AUTHORIZE_BINDING.replace("digest, reserved.owner)", "digest, in.RequestId)"),
        "Authorize must bind reserved.owner",
    ),
    *(
        mutation
        for file, path, guard in (
            ("infer.go", "result", RESULT_GUARD),
            ("inference_request.go", "attempt", ATTEMPT_GUARD),
        )
        for mutation in (
            Mutation(
                f"{path} transaction: hide the owner guard behind else if",
                file,
                guard,
                "\t\tif e == nil {\n\t\t} else " + guard.lstrip(),
                f"{path} path must reject a superseded or expired owner",
            ),
            Mutation(
                f"{path} transaction: jump over the owner guard using goto",
                file,
                guard,
                "\t\tgoto skipOwnerGuard\n" + guard + "\tskipOwnerGuard:\n",
                f"{path} path must not use goto",
            ),
        )
    ),
)


PRIVATE_GIT = ROOT.parent / "tmp" / "freeze" / "objects.git"
SERVER_BASELINE: str | None = None


def git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if PRIVATE_GIT.is_dir():
        environment["GIT_DIR"] = str(PRIVATE_GIT)
        environment["GIT_WORK_TREE"] = str(ROOT)
    return environment


def server_manifest() -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in (ROOT / "server").rglob("*") if p.is_file()):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def require_clean_server() -> None:
    global SERVER_BASELINE
    current = server_manifest()
    if SERVER_BASELINE is None:
        SERVER_BASELINE = current
    elif current != SERVER_BASELINE:
        raise AssertionError("server source changed during mutation replay")


def run_target(file: Path | None = None, source: str | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, "-B"]
    if file is None:
        command += ["-m", "unittest", "-v", TARGET]
    else:
        command += ["-c", RUN_OVERLAY, TARGET, str(file)]
    return subprocess.run(
        command,
        cwd=ROOT,
        input=source,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        env=git_environment(),
    )


def replay(mutation: Mutation) -> tuple[int, subprocess.CompletedProcess[str]]:
    path = PROFILE / mutation.file
    original = (ROOT / path).read_text(encoding="utf-8")
    changed, line = replace_once(original, mutation.original, mutation.replacement, path)
    if mutation.extra:
        changed, _ = replace_once(changed, *mutation.extra, path)
    result = run_target(path, changed)
    require_clean_server()
    return line, result


def replace_once(source: str, original: str, replacement: str, path: Path) -> tuple[str, int]:
    before, found, after = source.partition(original)
    if not found or found in after:
        raise ValueError(f"expected one mutation site in {path}: {original!r}")
    shared = commonprefix((original, replacement))
    return before + replacement + after, before.count("\n") + shared.count("\n") + 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    choices = parser.add_mutually_exclusive_group()
    choices.add_argument("--review", action="store_const", dest="mutations", const=REVIEW_MUTATIONS)
    choices.add_argument("--review2", action="store_const", dest="mutations", const=SECOND_REVIEW_MUTATIONS)
    mutations = parser.parse_args().mutations or MUTATIONS
    require_clean_server()
    initial = run_target()
    print(f"Candidate, expected exit 0, actual {initial.returncode}\n{initial.stdout}")
    if initial.returncode != 0:
        return 1

    passed = 0
    for number, mutation in enumerate(mutations, 1):
        line, result = replay(mutation)
        _, _, failure = result.stdout.partition("AssertionError:")
        hit = next(
            (
                line for line in failure.splitlines() if mutation.assertion in line
            ),
            None,
        )
        print(f"{number}. {PROFILE / mutation.file}:{line} — {mutation.description}")
        print(f"   Expected exit 1, actual {result.returncode}. Disk source intact.")
        if result.returncode == 1 and hit and "FAILED (failures=1)" in result.stdout:
            passed += 1
            print(f"   AssertionError: {hit[hit.rindex(mutation.assertion):]}")
        else:
            print(f"   Expected assertion: {mutation.assertion}\n{result.stdout}")
    require_clean_server()
    final = run_target()
    print(f"Candidate after replay, expected exit 0, actual {final.returncode}\n{final.stdout}")
    print(f"Mutations rejected by their expected assertions: {passed}/{len(mutations)}")
    return int(final.returncode != 0 or passed != len(mutations))


if __name__ == "__main__":
    sys.exit(main())
