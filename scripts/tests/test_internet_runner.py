import subprocess
import sys
import unittest
from pathlib import Path

RUNNER=Path(__file__).with_name('internet_acceptance.py')

class InternetRunnerSafety(unittest.TestCase):
    def test_physical_serial_is_rejected_before_any_adb_operation(self):
        result=subprocess.run([sys.executable,str(RUNNER),'--sdk','/nonexistent-sdk','--serial','real-phone'],capture_output=True,text=True)
        self.assertEqual(2,result.returncode)
        self.assertIn('never installs on physical devices',result.stderr)

    def test_invalid_method_is_rejected_before_any_adb_operation(self):
        result=subprocess.run([sys.executable,str(RUNNER),'--sdk','/nonexistent-sdk','--case','method;unexpected'],capture_output=True,text=True)
        self.assertEqual(2,result.returncode)
        self.assertIn('Invalid method',result.stderr)

if __name__=='__main__':unittest.main()
