#!/usr/bin/env python3
"""Presence's own demo profiles must not drift with the imported reference fixture."""
import importlib.util
import pathlib
import unittest


class PresenceSeedTests(unittest.TestCase):
    def setUp(self):
        path = pathlib.Path(__file__).parent / 'fixtures/presence-gateway.py'
        spec = importlib.util.spec_from_file_location('presence_seed_test', path)
        assert spec is not None and spec.loader is not None
        self.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.fixture)
        self.fixture.seed_meta()
        self.fixture.reset()

    def test_default_and_ivy_are_the_seed_on_both_profile_routes(self):
        fixture = self.fixture
        self.assertEqual(set(fixture.voice.SIDS), {'default', 'ivy'})
        for rpc in (fixture.base.rpc, fixture.voice.rpc):
            rows = rpc('profiles.list', {})['profiles']
            self.assertEqual({row['name'] for row in rows}, {'default', 'ivy'})
            ivy = next(row for row in rows if row['name'] == 'ivy')
            self.assertEqual(ivy['ui_meta']['hermes-bots']['display_name'], 'Ivy')
            self.assertEqual(ivy['canonical_session']['profile'], 'ivy')
            self.assertEqual(ivy['canonical_session']['id'], fixture.voice.SIDS['ivy'])

    def test_ivy_can_resume_without_falling_back_to_default(self):
        fixture = self.fixture
        self.assertIn('ivy', fixture.voice.SIDS)
        sid = fixture.voice.SIDS['ivy']
        reply = fixture.base.rpc('session.resume', {'profile': 'ivy', 'session_id': sid})
        self.assertEqual(reply['stored_session_id'], sid)
        self.assertEqual(reply['info']['profile_name'], 'ivy')
        self.assertEqual(reply['message_count'], 1)
        self.assertFalse(reply['running'])

    def test_ivy_browser_uses_its_own_chat_session(self):
        fixture = self.fixture
        fixture.control({'browsers': [{'profile': 'ivy', 'active': True}]})
        row = fixture.listing()['browsers'][0]
        self.assertTrue(row['session_id'], 'Ivy must have a real seeded session')
        self.assertEqual(row['session_id'], fixture.voice.SIDS['ivy'])
        self.assertEqual(row['session_ids'], [fixture.voice.SIDS['ivy']])
        self.assertNotEqual(row['session_id'], fixture.voice.SIDS['default'])

    def test_reset_keeps_seed_and_added_stress_bots_consistent(self):
        fixture = self.fixture
        fixture.add_bots(2)
        fixture.seed_meta()
        fixture.reset()
        expected = {'default', 'ivy', 'bot-01', 'bot-02'}
        for mapping in (fixture.voice.SIDS, fixture.base.MESSAGES, fixture.base.RUNNING,
                        fixture.base.CANCEL, fixture.META, fixture.REVS):
            self.assertEqual(set(mapping), expected)
        for profile in expected:
            self.assertEqual(len(fixture.base.MESSAGES[profile]), 1)
            self.assertFalse(fixture.base.RUNNING[profile])
            self.assertEqual(fixture.voice.row(profile)['profile'], profile)
        self.assertEqual(len(set(fixture.voice.SIDS.values())), len(expected))


if __name__ == '__main__':
    unittest.main(verbosity=2)
