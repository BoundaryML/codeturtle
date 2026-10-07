import importlib.util
import json
from pathlib import Path
import time
import unittest
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

spec=importlib.util.spec_from_file_location('crypto_helper',Path(__file__).resolve().parents[1] / 'crypto.py')
crypto=importlib.util.module_from_spec(spec); spec.loader.exec_module(crypto)

class CryptoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        cls.pem=cls.key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
        cls.jwk=json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(cls.key.public_key())); cls.jwk['kid']='one'
    def request(self,**claims):
        body={'iss':'issuer','aud':'audience','sub':'subject','iat':int(time.time())-1,'exp':int(time.time())+60,**claims}
        return {'operation':'verify','token':jwt.encode(body,self.pem,algorithm='RS256',headers={'kid':'one'}),'jwks':{'keys':[self.jwk]},'issuer':'issuer','audience':'audience'}
    def test_valid(self): self.assertEqual(crypto.execute(self.request())['claims']['sub'],'subject')
    def test_reject_claims(self):
        for claims in [{'iss':'evil'},{'aud':'evil'},{'exp':0},{'iat':int(time.time())+500},{'aud':['audience','evil']}]:
            with self.subTest(claims=claims),self.assertRaises(Exception): crypto.execute(self.request(**claims))
    def test_duplicate_kid(self):
        req=self.request();req['jwks']['keys']*=2
        with self.assertRaises(Exception): crypto.execute(req)
    def test_algorithm_substitution(self):
        req=self.request();req['token']=jwt.encode({'sub':'bad'},'secret',algorithm='HS256',headers={'kid':'one'})
        with self.assertRaises(Exception): crypto.execute(req)
    def test_sign(self):
        token=crypto.execute({'operation':'sign','app_id':'42','key':self.pem})['token']
        claims=jwt.decode(token,self.key.public_key(),algorithms=['RS256'])
        self.assertEqual(claims['iss'],'42');self.assertLessEqual(claims['exp']-claims['iat'],600)
if __name__=='__main__':unittest.main()
