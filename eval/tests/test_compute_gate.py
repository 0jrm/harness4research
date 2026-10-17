"""lib/compute-gate: an entrypoint on guard/budget.card's compute line, started outside a Slurm job, stops with two
lines; inside a job, unlisted, or with no card it runs. The forms are the ones E6's spec names, plus the ones that run
another listed script on the way."""
import os
import subprocess
import tempfile
import unittest

GATE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "lib", "compute-gate")
JOB = "#!/bin/bash\n#SBATCH --time=00:10:00\npython3 sim.py\n"


def sh(cwd, cmd, **env):
    full = {"PATH": os.environ["PATH"], "HOME": os.path.dirname(cwd), "BASH_ENV": os.path.join(GATE, "bash_env.sh"),
            "PYTHONPATH": GATE, **env}
    return subprocess.run(["bash", "-lc", cmd], cwd=cwd, env=full, capture_output=True, text=True)


class ComputeGate(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = tmp.name
        self.proj = os.path.join(tmp.name, "ocean-sim")
        os.makedirs(os.path.join(self.proj, "guard"))
        os.makedirs(os.path.join(self.proj, "x"))
        files = {"sim.py": "print('ran')\n", "job.sh": JOB, "other.py": "print('ran')\n",
                 "guard/budget.card": "account: gom\ncompute: sim.py job.sh\n"}
        for rel, text in files.items():
            with open(os.path.join(self.proj, rel), "w") as f:
                f.write(text)
        os.chmod(os.path.join(self.proj, "job.sh"), 0o755)
        os.chmod(os.path.join(self.proj, "sim.py"), 0o755)
        git = ["git", "-C", self.proj]
        subprocess.run(git + ["init", "-q", "-b", "main"], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "start"], check=True)
        subprocess.run(git + ["update-ref", "refs/remotes/origin/main", "HEAD"], check=True)

    def refused(self, cmd, what):
        r = sh(self.proj, cmd)
        self.assertEqual(r.returncode, 2, cmd)
        self.assertNotIn("ran", r.stdout, cmd)
        lines = r.stderr.splitlines()
        self.assertEqual(len(lines), 2, cmd)
        self.assertTrue(lines[0].startswith(f"guard compute: refused {what} outside a Slurm job"), cmd)
        self.assertIn("guard/run preflight runs/sim job.sh", lines[1], cmd)
        return lines

    def test_listed_entrypoints_refused_on_the_login_node(self):
        for cmd, what in [("python3 sim.py", "sim.py"), ("python3 ./sim.py --max-steps 1", "sim.py"),
                          ("bash job.sh", "job.sh"), ("./job.sh", "job.sh"), ("./sim.py", "sim.py"),
                          ("cd x && python3 ../sim.py", "sim.py"), ("sh job.sh", "sim.py")]:
            self.refused(cmd, what)

    def test_from_another_directory_the_command_starts_with_cd(self):
        lines = self.refused("cd .. && python3 ocean-sim/sim.py", "sim.py")
        self.assertEqual(lines[1], "Submit it instead: cd ~/ocean-sim && guard/run preflight runs/sim job.sh")

    def test_a_committed_run_names_its_directory(self):
        os.makedirs(os.path.join(self.proj, "runs", "r1"))
        open(os.path.join(self.proj, "runs", "r1", "question.card"), "w").close()
        r = sh(self.proj, "python3 sim.py")
        self.assertIn("guard/run preflight runs/r1 job.sh", r.stderr)

    def test_inside_a_job_unlisted_or_unrelated_it_runs(self):
        self.assertEqual(sh(self.proj, "bash job.sh", SLURM_JOB_ID="1000").stdout, "ran\n")
        self.assertEqual(sh(self.proj, "python3 other.py").stdout, "ran\n")
        self.assertEqual(sh(self.proj, "python3 -c 'print(1)' && echo ok").stdout, "1\nok\n")

    def test_the_card_on_the_protected_branch_decides(self):
        with open(os.path.join(self.proj, "guard", "budget.card"), "w") as f:
            f.write("account: gom\ncompute: none\n")
        self.refused("python3 sim.py", "sim.py")
        subprocess.run(["git", "-C", self.proj, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "x"],
                       check=True)
        subprocess.run(["git", "-C", self.proj, "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
        self.assertEqual(sh(self.proj, "python3 sim.py").stdout, "ran\n")

    def test_outside_a_checkout_it_runs(self):
        sim = os.path.join(self.home, "sim.py")
        with open(sim, "w") as f:
            f.write("print('ran')\n")
        self.assertEqual(sh(self.home, "python3 sim.py").stdout, "ran\n")


if __name__ == "__main__":
    unittest.main()
