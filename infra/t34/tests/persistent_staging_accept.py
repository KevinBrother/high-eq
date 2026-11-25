#!/usr/bin/env python3
"""Opt-in host entry for the disposable, in-process T34 persistence proof."""
import argparse
import os
import re
from pathlib import Path
import secrets
import signal
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from isolated_staging_lab import (HERE, REVISION, IsolatedLab, SafetyError, isolated_engine,
                                  namespace, staging)
from isolated_staging import ProofError, quiet, run_proof
import inputs
import release
import release_approval


ALLOW = 'T34_ALLOW_ISOLATED_STAGING_TEST'
RUN_ID_ENV = 'T34_ISOLATED_STAGING_RUN_ID'


class ArgumentError(ValueError):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ArgumentError('invalid command line')


def error_kind(error):
    # Fixed vocabulary, including for unexpected exception classes.
    for cls in (SafetyError, ProofError, ArgumentError, KeyboardInterrupt, ValueError,
                RuntimeError, OSError, KeyError, TypeError, AssertionError):
        if isinstance(error, cls):
            return cls.__name__
    return 'UnexpectedError'


class Report:
    stage = 'authorize'

    def passed(self):
        print('PASS ' + self.stage, flush=True)

    def failed(self, error):
        print('FAIL ' + self.stage + ' ' + error_kind(error), file=sys.stderr, flush=True)


def materialize(repo, base, revision, previous, tree=None):
    source, prior = base / 'candidate', base / 'prior'
    base.mkdir(mode=0o700)
    # Explicit Git objects, never an arbitrary build directory or inherited candidate tree.
    if tree is None:
        commit = inputs._git(repo, 'rev-parse', '--verify', revision + '^{commit}')
        tree = inputs._git(repo, 'rev-parse', '--verify', commit + '^{tree}')
    inputs.stage_inputs(repo, source, prior, tree=tree, previous_commit=previous)
    return SimpleNamespace(source=source, prior=prior, revision=revision, previous=previous,
                           preview=False, stage_test=False, ci_staging=True)


def cleanup(box, report):
    previous_stage = report.stage
    report.stage = 'cleanup'
    quiet(box.clean)
    report.passed()
    report.stage = previous_stage


def execute(args, run_id, report):
    # Refuse before Git object access or any Docker command unless the caller
    # supplied the explicit, non-default isolated engine endpoint and identity.
    engine = isolated_engine(os.environ)
    report.stage = 'validate-inputs'
    repo = Path(inputs._git(HERE.parents[1], 'rev-parse', '--show-toplevel'))
    with TemporaryDirectory(prefix='t34-proof-') as folder:
        work = Path(folder)
        first = materialize(repo, work / 'first', args.revision or 'archive-' + args.candidate_tree,
                            args.previous, tree=args.candidate_tree)
        second = first
        if args.update_revision and args.update_revision != args.revision:
            second = materialize(repo, work / 'second', args.update_revision, args.previous)
        comp1, schema = release.validate_release(
            first.source, first.prior, first.previous, args.decoder_approvals)
        comp2, update_schema = release.validate_release(
            second.source, second.prior, second.previous, args.decoder_approvals)
        if update_schema != schema:
            raise ProofError('update input schema differs')
        box = IsolatedLab(work, (first.source, first.prior, second.source), run_id, *engine)
        try:
            run_proof(box, first, second, work, (comp1, comp2), schema, report)
        except BaseException:
            # Keep the original failure authoritative. A cleanup failure is reported as
            # an additional safe error kind, but must not replace the proof failure stage.
            failure_stage = report.stage
            if box.armed:
                try:
                    cleanup(box, report)
                except BaseException as cleanup_error:
                    report.failed(cleanup_error)
                    report.stage = failure_stage
            raise
        else:
            if box.armed:
                cleanup(box, report)


def interrupted(*_):
    raise KeyboardInterrupt


def main(argv=None):
    report = Report()
    try:
        if os.environ.get(ALLOW) != '1':
            raise SafetyError('authorization missing')
        if staging.STATE_VOLUME_ENV in os.environ:
            raise SafetyError('self-hosted staging input forbidden')
        report.stage = 'arguments'
        parser = Parser(description=__doc__)
        parser.add_argument('revision', nargs='?', help='trusted candidate Git commit (full SHA-1)')
        parser.add_argument('--candidate-tree', help='trusted candidate tree object instead of a commit')
        parser.add_argument('--previous', required=True, help='compatible initial rollback commit')
        parser.add_argument('--update-revision', help='compatible update commit (default: candidate)')
        parser.add_argument('--decoder-approvals', type=Path,
                            default=os.environ.get(release_approval.APPROVALS_ENV),
                            help='absolute detached decoder approval outside the checkout')
        args = parser.parse_args(argv)
        commits = (args.revision, args.previous, args.update_revision)
        if ((args.revision is None) == (args.candidate_tree is None) or
                not all(value is None or REVISION.fullmatch(value) for value in commits) or
                (args.candidate_tree is not None and not re.fullmatch(r'[0-9a-f]{40,64}', args.candidate_tree))):
            raise ArgumentError('full Git object IDs required')
        release_approval.load_document(args.decoder_approvals, (HERE.parents[1],))
        run_id = os.environ.get(RUN_ID_ENV)
        if run_id is None:
            run_id = secrets.token_hex(12)
        print('namespace=' + namespace(run_id), flush=True)
        execute(args, run_id, report)
        report.stage = 'persistence-proof'
        report.passed()
        return 0
    except (Exception, KeyboardInterrupt) as error:
        report.failed(error)
        return 1


if __name__ == '__main__':
    os.umask(0o077)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    sys.exit(main())
