#!/usr/bin/env python3
"""Deterministic Atlas controller regression; no live model, GUI or network."""
import json, sys, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from vera_atlas_controller import inspect, cycle, INTERVAL_MS

NOW=1795020000000
A="1"*32
B="2"*32

class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        root=Path(self.tmp.name)
        self.bus=root/"bus.jsonl"
        self.ack=root/"ack.json"
        self.bus.write_text("")
        self.write_ack([A])
    def tearDown(self):self.tmp.cleanup()
    def event(self,id,age_ms=50000,operation="flash"):
        ts=datetime.fromtimestamp((NOW-age_ms)/1000,timezone.utc).isoformat()
        with self.bus.open("a") as f:
            f.write(json.dumps({"type":"memory_access","id":id,"operation":operation,"timestamp":ts})+"\n")
    def write_ack(self,ids,started=None):
        self.ack.write_text(json.dumps({"protocol":1,"kind":"javascript_accepted",
            "started_ms":NOW-100000 if started is None else started,
            "at_ms":NOW-500,"ids":ids}))
    def get(self,now=NOW):return inspect(self.bus,self.ack,now)
    def test_accepted(self):
        self.event(A)
        x=self.get()
        self.assertEqual((x["status"],x["acknowledged"],x["missing"]),("observed",1,0))
    def test_real_missing(self):
        self.event(B)
        self.assertEqual(self.get()["status"],"delivery_gap")
        self.assertEqual(self.get()["missing_flash"],1)
    def test_inflight_grace(self):
        self.event(B,age_ms=3000)
        self.assertEqual(self.get()["status"],"idle")
    def test_old_event_prior_to_widget(self):
        self.write_ack([],started=NOW-20000)
        self.event(B,age_ms=50000)
        self.assertEqual(self.get()["status"],"idle")
    def test_no_receipt_is_unknown_not_success(self):
        self.ack.unlink()
        self.event(A)
        self.assertEqual(self.get()["status"],"ack_unavailable")
    def test_duplicate_incident_reopens_only_once(self):
        self.event(B)
        state={}
        self.assertTrue(cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW))
        self.assertEqual(state["controller"]["incidents"]["bus_to_atlas"]["checks"],1)
        self.assertFalse(cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+1000))
        self.assertTrue(cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+INTERVAL_MS+100))
        self.assertEqual(state["controller"]["incidents"]["bus_to_atlas"]["checks"],2)
        self.write_ack([B])
        self.assertTrue(cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+2*INTERVAL_MS+200))
        self.assertEqual(state["controller"]["incidents"]["bus_to_atlas"]["state"],"resolved_by_observation")
    def test_nonvisual_snapshot_is_not_a_lost_flash(self):
        self.event(B,operation="process-event")
        self.assertEqual(self.get()["status"],"idle")
    def test_dead_widget_is_distinct_from_idle(self):
        r=json.loads(self.ack.read_text())
        r.update(pid=99999999,at_ms=NOW-70000)
        self.ack.write_text(json.dumps(r))
        self.assertEqual(self.get()["status"],"widget_stopped")
    def test_observer_scan_failure_opens_single_ticket(self):
        state={}
        cycle(state,failures=1,bus=self.bus,ack_path=self.ack,now_ms=NOW)
        self.assertEqual(state["controller"]["incidents"]["source_to_bus"]["checks"],1)
    def test_repair_handoff_requires_explicit_callback(self):
        self.event(B)
        state={}
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW)
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+INTERVAL_MS+1)
        incident=state["controller"]["incidents"]["bus_to_atlas"]
        self.assertEqual(incident["state"],"needs_attention")
        self.assertNotIn("sent_ms",incident)
        calls=[]
        state={}
        def handoff(kind,evidence):
            calls.append((kind,evidence.copy()))
            return {"accepted":True}
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW,dispatcher=handoff)
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+INTERVAL_MS+1,dispatcher=handoff)
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW+2*INTERVAL_MS+2,dispatcher=handoff)
        self.assertEqual(len(calls),1)
        self.assertEqual(state["controller"]["incidents"]["bus_to_atlas"]["state"],"assigned")
    def test_never_fabricates_events(self):
        before=self.bus.read_bytes()
        state={}
        cycle(state,bus=self.bus,ack_path=self.ack,now_ms=NOW)
        self.assertEqual(before,self.bus.read_bytes())
if __name__=="__main__": unittest.main()
