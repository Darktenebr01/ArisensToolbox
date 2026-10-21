import unittest

from bridge.enums import parse_enums


SAMPLE = "\n".join([
    "custom\t101\tJob01_Fighter",
    "custom\t102\tJob02_Archer",
    "normal\t201\tJob01_Warrior",
    "ability\t301\tJob01_Core",
    "ability\t302\tOtherAbility",
    "equipskill\t5\tShield",
    "enhance\t7\tStrength",
    "level\t3\tLevel 3",
])


class ParseEnumsTests(unittest.TestCase):
    def setUp(self):
        self.data = parse_enums(SAMPLE)

    def test_custom_jobs_are_split_by_job_number(self):
        fighter = self.data["jobsCustom"][0]
        archer = self.data["jobsCustom"][1]
        self.assertEqual(fighter["labels"], ["(none)", "Fighter"])
        self.assertEqual(fighter["ids"], [0, 101])
        self.assertEqual(archer["labels"], ["(none)", "Archer"])
        self.assertEqual(self.data["customName"][101], "Fighter")

    def test_abilities_keep_prefix_and_land_in_other_bucket(self):
        core = self.data["jobsAbility"][0]
        self.assertIn("Job01_Core", core["labels"])
        other = self.data["jobsAbility"][1]
        self.assertIn("[other] OtherAbility", other["labels"])

    def test_equipment_and_labels(self):
        self.assertEqual(self.data["equipList"], [(5, "Shield")])
        self.assertEqual(self.data["equipName"][5], "Shield")
        self.assertEqual(self.data["enhLabels"], ["Strength (7)"])
        self.assertEqual(self.data["levelLabels"], ["Level 3 (3)"])

    def test_missing_levels_have_fallback(self):
        data = parse_enums("")
        self.assertEqual(data["levelLabels"], ["0", "1", "2"])
        self.assertEqual(data["levelValues"], [0, 1, 2])

    def test_bad_lines_are_ignored(self):
        data = parse_enums("custom\tnot-a-number\tBad\nno-tabs\n")
        self.assertEqual(data["customName"], {})


if __name__ == "__main__":
    unittest.main()
