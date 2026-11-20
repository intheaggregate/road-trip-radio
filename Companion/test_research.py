import http.client
import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from research import Busy, Desk, context, handler, normalized, validate_pack

BODY = {"mode":"live","places":["Memphis, Tennessee, US"],"energy":"Mellow","weather":"Rain"}
PASSAGE = "The band recorded this very song in this building."
ENTRY = {"place":"A studio","latitude":35.1,"longitude":-90.2,"title":"A Song","artist":"The Band",
         "reason":"Recorded here.","source":"https://example.org/history","evidence":PASSAGE}

class ResearchTests(unittest.TestCase):
    def test_valid_evidence_and_rejection(self):
        data = {"stories":[ENTRY, ENTRY | {"title":"Another Song","source":"https://example.org/no","evidence":"A different passage with enough words."},
                           ENTRY | {"latitude":101}, ENTRY]}
        pack = validate_pack(data,context(BODY),lambda url:normalized(PASSAGE))
        self.assertEqual(len(pack["stories"]),1)
        self.assertNotIn("evidence",pack["stories"][0])
        self.assertEqual(pack["version"],1)
    def test_one_studio_can_document_two_recordings(self):
        rows = [ENTRY, ENTRY | {"title":"Another Song"}]
        self.assertEqual(len(validate_pack({"stories":rows},context(BODY),lambda _:normalized(PASSAGE))["stories"]),2)
    def test_only_named_context(self):
        for bad in (BODY | {"spotify_tracks":["x"]}, BODY | {"places":["a","b"]}, BODY | {"weather":"anything"}, BODY | {"places":["a\nb"]}):
            with self.assertRaises(ValueError): context(bad)
    def test_cached_request_and_rate_limit(self):
        desk = Desk(lambda body: {"version":1,"name":"Town","stories":[]})
        self.addCleanup(desk.pool.shutdown)
        one = desk.submit(BODY); desk.jobs[one][2].result(timeout=2)
        self.assertEqual(desk.submit(BODY),one)
        self.assertEqual(desk.poll(one)[0],200)
        with self.assertRaises(Busy): desk.submit(BODY | {"places":["Another town"]})
    def test_paired_http_roundtrip(self):
        desk = Desk(lambda _: {"version":1,"name":"Town","stories":[]})
        server = ThreadingHTTPServer(("127.0.0.1",0),handler(desk,"paired"))
        worker = threading.Thread(target=server.serve_forever,daemon=True); worker.start()
        def clean():
            server.shutdown(); server.server_close(); worker.join(); desk.pool.shutdown()
        self.addCleanup(clean)
        connection = http.client.HTTPConnection("127.0.0.1",server.server_port,timeout=2)
        connection.request("GET","/v1/status"); self.assertEqual(connection.getresponse().status,401)
        connection.close()
        auth = {"Authorization":"Bearer paired","Content-Type":"application/json"}
        connection.request("POST","/v1/research",json.dumps(BODY),headers=auth)
        response = connection.getresponse(); self.assertEqual(response.status,202)
        job = json.loads(response.read())["id"]
        desk.jobs[job][2].result(timeout=2); connection.close()
        connection.request("GET","/v1/research/"+job,headers=auth)
        response = connection.getresponse(); self.assertEqual(response.status,200)
        self.assertEqual(json.loads(response.read())["name"],"Town"); connection.close()
