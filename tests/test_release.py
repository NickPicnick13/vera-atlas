"""Public-release tests: synthetic-only data, metadata-only events."""
from __future__ import annotations
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from vera_atlas_access import new_access_id, record_access

class PublicReleaseTests(unittest.TestCase):
    def test_synthetic_graph_complete(self):
        graph = json.loads((ROOT / "examples/demo-graph.json").read_text())
        nodes, edges = graph["nodes"], graph["edges"]
        self.assertEqual(len(nodes), 4506)
        self.assertEqual(len(edges), 4786)
        ids = {node["id"] for node in nodes}
        self.assertEqual(len(ids), len(nodes))
        self.assertTrue(all(i.startswith("demo-") for i in ids))
        self.assertTrue(all(e["a"] in ids and e["b"] in ids for e in edges))
        self.assertTrue(all(set(n.keys()) == {"id","g","w"} for n in nodes))
        self.assertTrue(all(set(e.keys()) == {"a","b","w"} for e in edges))

    def test_metadata_event_and_catalog(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "events.jsonl"
            model, task, process = "m-"+"a"*24, "q-"+"b"*24, "r-"+"c"*24
            self.assertTrue(record_access("process-event",new_access_id(),
                    path=path,model_id=model,stage="configured"))
            self.assertTrue(record_access("process-event",new_access_id(),
                    path=path,model_id=model,task_id=task,
                    process_id=process,stage="started"))
            self.assertTrue(record_access("process-event",new_access_id(),
                    path=path,model_id=model,task_id=task,
                    process_id=process,stage="result",outcome="completed"))
            self.assertFalse(record_access("process-event",new_access_id(),
                    path=path,model_id="RawProviderName",stage="configured"))
            rows = [json.loads(l) for l in path.read_text().splitlines()]
            self.assertEqual(len(rows),4)
            self.assertEqual(rows[0]["type"],"atlas_catalog")
            self.assertEqual(rows[0]["process_models"],[model])
            self.assertIn([process,model,task],rows[0]["process_instances"])
            self.assertEqual(rows[-1]["outcome"],"completed")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)

    def test_process_wrapper_real_exit_codes(self):
        with tempfile.TemporaryDirectory() as root:
            path=pathlib.Path(root)/"events.jsonl"
            env={**os.environ,"VERA_ATLAS_ACCESS_PATH":str(path)}
            wrapper=ROOT/"scripts/vera_atlas_chatgpt_workbench.py"
            for value in (0,7):
                finished=subprocess.run([sys.executable,"-B",str(wrapper),
                       "--","/bin/sh","-c",f"exit {value}"],
                       env=env,capture_output=True,text=True,timeout=10)
                self.assertEqual(finished.returncode,value)
            data=[json.loads(x) for x in path.read_text().splitlines()]
            spans=[x for x in data if x.get("origin")=="chatgpt"]
            self.assertEqual([x["operation"] for x in spans],
                ["tool","tool-result","tool","tool-result"])
            self.assertEqual([x["outcome"] for x in spans if "outcome" in x],
                ["returned","error"])
            self.assertNotEqual(spans[0]["process_id"],spans[2]["process_id"])
            self.assertEqual(len(data[0]["chatgpt_processes"]),2)
            self.assertNotIn("exit 7",path.read_text())

    def test_demo_script_no_provider(self):
        with tempfile.TemporaryDirectory() as root:
            path=pathlib.Path(root)/"events.jsonl"
            env={**os.environ,"VERA_ATLAS_ACCESS_PATH":str(path)}
            command=[sys.executable,"-B",str(ROOT/"examples/emit_demo_activity.py"),
                     "--count","2","--delay","0"]
            result=subprocess.run(command,capture_output=True,text=True,
                                  env=env,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            rows=[json.loads(x) for x in path.read_text().splitlines()]
            self.assertEqual(sum(x.get("stage")=="started" for x in rows),2)
            self.assertEqual(sum(x.get("stage")=="result" for x in rows),2)

    def test_document_and_project_observation_requires_explicit_roots(self):
        from unittest.mock import patch
        from vera_atlas_skill_watch import document_event, project_id_for_document

        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            approved = base / "approved"
            project = approved / "sample-project"
            project.mkdir(parents=True)
            document = project / "sample.md"
            document.write_text("synthetic fixture")
            outside = base / "outside"
            outside.mkdir()
            other = outside / "sample.md"
            other.write_text("synthetic fixture")
            protected = project / "secret-settings.md"
            protected.write_text("synthetic fixture")
            with patch.dict(os.environ, {"VERA_ATLAS_DOCUMENT_ROOTS": "",
                                      "VERA_ATLAS_PROJECTS_ROOT": ""}):
                self.assertIsNone(document_event(str(document), str(project)))
                self.assertIsNone(project_id_for_document(str(document), str(project)))
            with patch.dict(os.environ, {"VERA_ATLAS_DOCUMENT_ROOTS": str(approved),
                                      "VERA_ATLAS_PROJECTS_ROOT": str(approved)}):
                doc = document_event(str(document), str(project))
                self.assertIsNotNone(doc)
                self.assertEqual(doc[0], "document")
                self.assertRegex(doc[1], r"^f-[0-9a-f]{24}$")
                self.assertRegex(project_id_for_document(str(document), str(project)),
                                 r"^p-[0-9a-f]{24}$")
                self.assertIsNone(document_event(str(other), str(outside)))
                self.assertIsNone(project_id_for_document(str(other), str(outside)))
                self.assertIsNone(document_event(str(protected), str(project)))
                self.assertIsNone(project_id_for_document(str(protected), str(project)))

    def test_no_private_assets(self):
        self.assertFalse((ROOT/"gsap.min.js").exists())
        self.assertFalse((ROOT/"PROJECT_CONTEXT.md").exists())
        for part in ("atlas.js","sphere.js","make_app.sh","proto.html",
                     "scripts/vera_atlas_controller.py","scripts/vera_atlas_skill_watch.py"):
            content=(ROOT/part).read_text()
            self.assertNotIn("/Users/",content)
        native=(ROOT/"Sources/VeraDesktopWidget/AtlasLiveData.swift").read_text()
        self.assertNotIn("Obsidian Vault",native)
        self.assertNotIn("live-trace-data.json",native)
        self.assertFalse((ROOT/".gitignore").is_dir())

if __name__ == "__main__":
    unittest.main()
