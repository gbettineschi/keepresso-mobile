import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_version", Path(__file__).parents[1] / "release-version.py")
versions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versions)


class ReleaseVersionTests(unittest.TestCase):
    def test_versions_order_android_updates(self):
        self.assertEqual(versions.release_version("v0.4.3"), ("0.4.3", 4003))
        self.assertLess(versions.release_version("v0.4.999")[1], versions.release_version("v0.5.0")[1])
        self.assertLess(versions.release_version("v0.999.999")[1], versions.release_version("v1.0.0")[1])

    def test_invalid_or_overflowing_tags_are_rejected(self):
        for tag in ["main", "v01.2.3", "v0.0.0", "v1.1000.0", "v1.0.1000", "v2101.0.0", "v1.2.3\n", "v1.2.3-beta"]:
            with self.assertRaises(ValueError, msg=tag):
                versions.release_version(tag)
