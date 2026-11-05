#!/usr/bin/env python3
"""Add cache-only Teum hooks; leave default models and permissions intact."""
from pathlib import Path
import argparse
import json
import os
import selectors
import shlex
import shutil
import sys
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]

def atomic(path,text):
    path.parent.mkdir(parents=True,exist_ok=True)
    temp=path.with_name(path.name+'.teum.tmp');temp.write_text(text);os.chmod(temp,0o600);os.replace(temp,path)

def discover(home,output):
    records=[]
    profiles = sorted({'.codex', *(x.name for x in home.glob('.codex-*') if (x/'auth.json').is_file())})
    codex = shutil.which('codex')
    if not codex: raise RuntimeError('codex를 PATH에서 찾을 수 없습니다.')
    for profile in profiles:
        env=dict(os.environ,CODEX_HOME=str(home/profile),PATH='/opt/homebrew/bin:'+str(home/'.local/bin')+':'+os.environ.get('PATH',''))
        proc=subprocess.Popen([codex,'app-server','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
        selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ);buffer=b''
        def rpc(i,method,params):
            nonlocal buffer
            proc.stdin.write((json.dumps({'id':i,'method':method,'params':params})+'\n').encode());proc.stdin.flush();end=time.monotonic()+25
            while time.monotonic()<end:
                while b'\n' in buffer:
                    line,buffer=buffer.split(b'\n',1)
                    try:value=json.loads(line)
                    except ValueError:continue
                    if value.get('id')==i:return value
                if selector.select(0.2):
                    data=os.read(proc.stdout.fileno(),1024*1024)
                    if not data:raise RuntimeError('Codex 발견 프로세스 종료')
                    buffer+=data
            raise RuntimeError('Codex 발견 검사 시간 초과')
        try:
            rpc(1,'initialize',{'clientInfo':{'name':'teum-install','version':'1.0'},'capabilities':{'experimentalApi':True}})
            proc.stdin.write(b'{"method":"initialized"}\n');proc.stdin.flush()
            hooks=rpc(2,'hooks/list',{'cwds':[str(ROOT)]});skills=rpc(3,'skills/list',{'cwds':[str(ROOT)],'forceReload':True})
            found=[]
            for group in hooks.get('result',{}).get('data',[]):
                for h in group.get('hooks',[]):
                    if str(ROOT/'cli/teum_cli.py') in h.get('command',''):found.append({k:h.get(k) for k in ['key','currentHash','enabled','trustStatus','eventName','command']})
            names=[s.get('name') for group in skills.get('result',{}).get('data',[]) for s in group.get('skills',[]) if s.get('name')=='teum-cli']
            records.append({'profile':profile,'hooks':found,'skills':names})
        finally:
            selector.close();proc.terminate()
            try:proc.wait(timeout=3)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(records,ensure_ascii=False,indent=2))
    return records

def main():
    p=argparse.ArgumentParser();p.add_argument('--home',type=Path,default=Path.home());p.add_argument('--trust-codex',action='store_true');p.add_argument('--uninstall',action='store_true');args=p.parse_args()
    home=args.home.expanduser().resolve();data=home/'Library/Application Support/Teum';backup=data/'integration-backups'/time.strftime('%Y%m%d-%H%M%S');backups=[]
    rule='---\ninclusion: always\n---\nTeum 사용량 훅을 참고합니다. 오래된 값은 자동 제어에 쓰지 않고 `~/.local/bin/teum-cli budget --host kiro --model 실제모델 --json`으로 확인합니다. 상세는 teum-cli 스킬을 읽습니다. 훅은 현재 모델을 강제로 바꾸지 않습니다. 새 단발 작업은 teum-cli run으로 모델·동시 실행·대기를 적용합니다. UI 경고 제외는 AI 예산 제외가 아닙니다.\n'
    steering=home/'.kiro/steering/teum-budget.md'
    steering_owned = steering.is_file() and steering.read_text() == rule
    if not args.uninstall and steering.exists() and not steering_owned:
        raise RuntimeError('기존 Kiro 규칙을 덮어쓰지 않습니다: '+str(steering))
    def save_json(path,mutate):
        path=path.resolve();old=path.read_text() if path.exists() else '{}';value=json.loads(old);mutate(value);new=json.dumps(value,ensure_ascii=False,indent=2)+'\n'
        if new==old:return
        dst=backup/path.relative_to(home);dst.parent.mkdir(parents=True,exist_ok=True);dst.write_text(old);os.chmod(dst,0o600);backups.append(str(dst))
        if path.exists() and path.read_text()!=old:raise RuntimeError('설정 동시 변경으로 중단: '+str(path))
        atomic(path,new)
    def link(path,target):
        path.parent.mkdir(parents=True,exist_ok=True)
        if path.is_symlink() and path.resolve()==target.resolve():return
        if path.exists() or path.is_symlink():raise RuntimeError('기존 파일을 덮어쓰지 않음: '+str(path))
        path.symlink_to(target,target_is_directory=target.is_dir())
    command=shlex.quote(sys.executable)+' '+shlex.quote(str(ROOT/'cli/teum_cli.py'))
    def standard(host):
        def mutate(d):
            hooks=d.setdefault('hooks',{})
            for event in ['SessionStart','UserPromptSubmit','PreToolUse']:
                groups=hooks.setdefault(event,[])
                for g in groups:g['hooks']=[h for h in g.get('hooks',[]) if str(ROOT/'cli/teum_cli.py') not in h.get('command','')]
                groups[:]=[g for g in groups if g.get('hooks')]
                if not args.uninstall:
                    h={'type':'command','command':command+' hook --host '+host+' --event '+event,'timeout':3}
                    if event=='PreToolUse':h['async']=True
                    groups.append({'hooks':[h]})
        return mutate
    skill_bases=['.claude/skills','.codex/skills','.agents/skills','.kiro/skills','.gemini/config/skills','.gemini/antigravity-cli/skills']
    if not args.uninstall:
        os.chmod(ROOT/'cli/teum_cli.py',0o755);link(home/'.local/bin/teum-cli',ROOT/'cli/teum_cli.py')
        for base in skill_bases:link(home/base/'teum-cli',ROOT/'cli/skill')
    save_json(home/'.claude/settings.json',standard('claude'));save_json(home/'.codex/hooks.json',standard('codex'))
    def agy(d):
        d.pop('paul-teum',None)
        if not args.uninstall:d['paul-teum']={e:[{'type':'command','command':command+' hook --host agy --event '+e,'timeout':3}] for e in ['SessionStart','PreInvocation']}
    save_json(home/'.gemini/config/hooks.json',agy)
    steering=home/'.kiro/steering/teum-budget.md'
    def kiro(d):
        hooks=d.setdefault('hooks',[]);hooks[:]=[h for h in hooks if not h.get('name','').startswith('teum-')]
        resources=d.setdefault('resources',[]);resources[:]=[x for x in resources if x!=steering.as_uri()]
        if not args.uninstall:
            for e in ['agentSpawn','userPromptSubmit','preToolUse']:hooks.append({'name':'teum-'+e,'trigger':e,'action':{'type':'command','command':command+' hook --host kiro --event '+e},'timeout':3})
            resources.append(steering.as_uri())
    save_json(home/'.kiro/agents/default.json',kiro)

    if not args.uninstall:atomic(steering,rule)
    else:
        for base in skill_bases:
            path=home/base/'teum-cli'
            if path.is_symlink() and path.resolve()==(ROOT/'cli/skill').resolve():path.unlink()
        path=home/'.local/bin/teum-cli'
        if path.is_symlink() and path.resolve()==(ROOT/'cli/teum_cli.py').resolve():path.unlink()
        if steering_owned:steering.unlink()
        elif steering.exists():print('수정된 Kiro 규칙은 보존했습니다: '+str(steering))
    discovery=[]
    if args.trust_codex and not args.uninstall:
        discovery=discover(home,data/'codex-teum-discovery.json');config=home/'.codex/config.toml';old=config.read_text();text=old
        for group in discovery:
            for h in group['hooks']:
                if not h.get('key') or not h.get('currentHash'):raise RuntimeError('훅 해시를 읽지 못했습니다.')
                header='[hooks.state.'+json.dumps(h['key'])+']';section=header+'\ntrusted_hash = '+json.dumps(h['currentHash'])+'\nenabled = true\n'
                if header in text:
                    start=text.index(header);end=text.find('\n[',start+len(header));end=len(text) if end<0 else end;text=text[:start]+section+text[end:]
                else:text+='\n'+section
        if text!=old:
            dst=backup/'.codex/config.toml';dst.parent.mkdir(parents=True,exist_ok=True);dst.write_text(old);os.chmod(dst,0o600);backups.append(str(dst))
            if config.read_text()!=old:raise RuntimeError('Codex 설정 동시 변경으로 신뢰 등록 중단')
            atomic(config,text)
        discovery=discover(home,data/'codex-teum-discovery.json')
    manifest={'installed':not args.uninstall,'installed_at':time.time(),'cli':str(home/'.local/bin/teum-cli'),'skill':str(ROOT/'cli/skill/SKILL.md'),'hook_mode':'cached guidance only; no permission changes','native_model_switch':'not claimed','launcher_enforcement':'teum-cli run only','backups':backups,'codex_discovery':discovery}
    atomic(data/'integration.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print('Teum 연결 '+('제거' if args.uninstall else '설치')+' 완료 · '+str(data/'integration.json'))

if __name__=='__main__':main()
