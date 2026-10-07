"""RS256 primitives only. No networking, state, or application authorization."""
import json
import sys
import time
import jwt


def execute(request):
    if request['operation'] == 'sign':
        now = int(time.time())
        return {'token': jwt.encode({'iat': now - 30, 'exp': now + 540, 'iss': request['app_id']}, request['key'], algorithm='RS256')}
    if request['operation'] != 'verify':
        raise ValueError()
    token = request['token']
    header = jwt.get_unverified_header(token)
    if header.get('alg') != 'RS256' or not isinstance(header.get('kid'), str):
        raise ValueError()
    keys = [k for k in request['jwks']['keys'] if k.get('kid') == header['kid'] and k.get('kty') == 'RSA' and k.get('use', 'sig') == 'sig' and k.get('alg', 'RS256') == 'RS256']
    if len(keys) != 1 or 'd' in keys[0]:
        raise ValueError()
    key = jwt.PyJWK.from_dict(keys[0], algorithm='RS256').key
    return {'claims': jwt.decode(token, key, algorithms=['RS256'], issuer=request['issuer'], audience=request['audience'],
                                 options={'require': ['exp', 'iat', 'iss', 'aud', 'sub'], 'strict_aud': True}, leeway=0)}


def main():
    try:
        raw = sys.stdin.buffer.read(131073)
        if len(raw) > 131072:
            raise ValueError()
        result = execute(json.loads(raw))
        print(json.dumps(result))
        return 0
    except Exception:
        print('{"error":"invalid_crypto_request"}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
