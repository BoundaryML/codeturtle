"""Install a pinned BAML runtime binary after SHA-256 verification. No shell downloads."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import tempfile
import tarfile
import shutil
import urllib.parse
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--url',required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--destination',type=Path,required=True)
    args=parser.parse_args()
    parsed=urllib.parse.urlsplit(args.url)
    if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password or not re.fullmatch('[0-9a-f]{64}',args.sha256):
        parser.error('An HTTPS runtime binary URL and SHA-256 are required')
    args.destination.parent.mkdir(parents=True,exist_ok=True)
    temp=None
    try:
        # Release hosts may redirect to signed asset URLs; no credentials are sent.
        opener=urllib.request.build_opener()
        with opener.open(args.url,timeout=60) as response, tempfile.NamedTemporaryFile(dir=args.destination.parent,delete=False) as stream:
            temp=Path(stream.name);digest=hashlib.sha256();size=0
            while chunk:=response.read(1024*1024):
                size+=len(chunk)
                if size>512*1024*1024:raise ValueError('Runtime exceeds size limit')
                digest.update(chunk);stream.write(chunk)
        if digest.hexdigest()!=args.sha256:raise ValueError('Runtime checksum mismatch')
        if tarfile.is_tarfile(temp):
            with tarfile.open(temp, 'r:*') as archive:
                candidates = [m for m in archive.getmembers() if m.isfile() and Path(m.name).name in ('baml', 'baml-cli')]
                if len(candidates) != 1 or candidates[0].size > 512*1024*1024:
                    raise ValueError('Expected exactly one BAML executable in archive')
                with archive.extractfile(candidates[0]) as source, tempfile.NamedTemporaryFile(dir=args.destination.parent, delete=False) as output:
                    executable = Path(output.name)
                    try:
                        shutil.copyfileobj(source, output)
                        output.flush()
                        executable.chmod(0o755)
                        os.replace(executable, args.destination)
                    finally:
                        if executable.exists(): executable.unlink()
        else:
            temp.chmod(0o755);os.replace(temp,args.destination)
    finally:
        if temp and temp.exists():temp.unlink()
if __name__=='__main__':main()
