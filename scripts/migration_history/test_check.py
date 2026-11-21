import unittest

from check import check_history


def pair(version, name):
    return {f'{version}_{name}.{direction}.sql': f'{name}-{direction}' for direction in ('up', 'down')}


class MigrationHistoryTest(unittest.TestCase):
    def setUp(self):
        self.live = pair('20261121191500', 'accounts')

    def test_several_later_pairs_are_allowed(self):
        tip = self.live | pair('20261121191501', 'gateway') | pair('20261122000100', 'admin_roles')
        check_history(self.live, tip)
        check_history({}, tip)
        check_history(tip, tip)

    def test_older_new_pair_would_be_skipped_on_upgrade(self):
        with self.assertRaisesRegex(ValueError, 'published'):
            check_history(self.live, self.live | pair('20261121000700', 'gateway'))

    def test_published_sql_cannot_be_removed_or_rewritten(self):
        for tip in ({}, {**self.live, next(iter(self.live)): 'edited'}):
            with self.subTest(tip=tip), self.assertRaisesRegex(ValueError, 'published'):
                check_history(self.live, tip)

    def test_version_collision_and_incomplete_or_malformed_pair(self):
        bad = [pair('20261121191500', 'extra'), {'20261122120000_new.up.sql': 'new'}, {'bad.sql': 'bad'}]
        for additions in bad:
            with self.subTest(additions=additions), self.assertRaises(ValueError):
                check_history({}, self.live | additions)
