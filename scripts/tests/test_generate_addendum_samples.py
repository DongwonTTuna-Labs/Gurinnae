from __future__ import annotations

import unittest

from scripts.materialize_application import operation_response_samples


class AddendumSampleGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.samples = operation_response_samples()

    def test_empty_public_downloads_keep_required_notice_slots(self) -> None:
        for operation_id in (
            "downloadPublicCases",
            "downloadPublicSearchRecords",
        ):
            with self.subTest(operation_id=operation_id):
                _, _, body = self.samples[operation_id]
                self.assertEqual(body["rowCount"], 0)
                self.assertEqual(body["nonConclusionNotices"], [])
                self.assertIsNone(body["interpretationNotice"])

    def test_command_receipts_bind_their_operation_id(self) -> None:
        command_bodies = {
            operation_id: body["command"]
            for operation_id, (_, _, body) in self.samples.items()
            if isinstance(body, dict)
            and isinstance(body.get("command"), dict)
            and "operationId" in body["command"]
        }

        self.assertLessEqual(
            {"createResponseAppeal", "createActionProposal"},
            set(command_bodies),
        )
        for operation_id, command in command_bodies.items():
            with self.subTest(operation_id=operation_id):
                self.assertEqual(command["operationId"], operation_id)


if __name__ == "__main__":
    unittest.main()
