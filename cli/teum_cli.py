#!/usr/bin/env python3
"""Local quota protocol, policy and supervised one-shot launches for Teum."""
from __future__ import annotations
import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get('TEUM_DATA_DIR', str(Path.home()/'Library/Application Support/Teum'))).expanduser()
NAMES = {'claude':'클로드','codex':'코덱스','agy-claude':'AGY 클로드','agy-general':'AGY 일반','kiro':'키로','grok':'그록'}
HOSTS = ['claude','codex','agy','kiro']
DEFAULT_POLICY = {'schema_version':1,'conserve_below':20.0,'critical_below':5.0,'stop_at':0.0,'max_age_seconds':600,'poll_seconds':60,'auto_switch':True,'streams':{},'models':{'claude':{'conserve':'sonnet','critical':'haiku'},'codex':{'conserve':'gpt-6-luna','critical':'gpt-6-luna'},'agy-general':{'conserve':'gemini-3.8-flash-medium','critical':'gemini-3.8-flash-low'},'agy-claude':{'conserve':'claude-sonnet-5-5-medium','critical':'claude-sonnet-5-5-low'},'kiro':{'conserve':'claude-sonnet-5.5','critical':'claude-sonnet-5.5'}}}

def read_json(path, default=None):
    try:
        with Path(path).open() as f: return json.load(f)
    except (OSError, ValueError): return copy.deepcopy(default)

def atomic_json(path, data):
    path = Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temp = path.with_name(path.name+'.'+str(os.getpid())+'.tmp')
    try:
        fd = os.open(str(temp),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f: json.dump(data,f,ensure_ascii=False,indent=2);f.write('\n')
        os.replace(temp,path)
    finally:
        with contextlib.suppress(FileNotFoundError): temp.unlink()

def stream_names(active=False):
    settings = read_json(DATA/'settings.json',{})
    configured = {x['id']:x.get('name',x['id']) for x in settings.get('streams',[]) if isinstance(x,dict) and isinstance(x.get('id'),str) and (x['id'] in NAMES or x.get('source')=='codex')}
    native = read_json(DATA/'cli-readings.json',{}).get('streamNames',{})
    if not isinstance(native,dict): native = {}
    if active and configured and 'notchStyle' in settings: return configured
    if active and native and not configured: return native
    return {**NAMES,**native,**configured}

def policy():
    result = copy.deepcopy(DEFAULT_POLICY)
    stored = read_json(DATA/'policy.json',{})
    if not isinstance(stored,dict): raise ValueError('policy.json은 JSON 객체여야 합니다.')
    result.update(stored)
    validate_policy(result)
    return result

def validate_policy(p):
    values = [p.get(x) for x in ['stop_at','critical_below','conserve_below']]
    if any(isinstance(x,bool) or not isinstance(x,(float,int)) or not math.isfinite(x) for x in values) or not 0 <= values[0] <= values[1] <= values[2] <= 100:
        raise ValueError('기준은 0 ≤ 멈춤 ≤ 긴축 ≤ 절약 ≤ 100이어야 합니다.')
    if not 30 <= p.get('max_age_seconds',0) <= 3600 or not 15 <= p.get('poll_seconds',0) <= 3600:
        raise ValueError('유효 시간은 30~3600초, 확인 간격은 15~3600초여야 합니다.')
    if not isinstance(p.get('streams'),dict) or not isinstance(p.get('models'),dict) or not isinstance(p.get('auto_switch'),bool): raise ValueError('정책 형식을 확인해 주세요.')
    for key,value in p.get('streams',{}).items():
        if key not in stream_names() or not isinstance(value,dict): raise ValueError('알 수 없는 스트림 정책입니다.')
        effective = dict(p);effective.update(value);effective['streams'] = {};validate_policy(effective)

def native_binary():
    override = os.environ.get('TEUM_COLLECTOR')
    candidates = [Path(override)] if override else [ROOT.parent/'MacOS/Teum',Path('/Applications/Teum.app/Contents/MacOS/Teum'),Path.home()/'Applications/Teum.app/Contents/MacOS/Teum',ROOT/'build/Teum.app/Contents/MacOS/Teum']
    for file in candidates:
        if file.is_file() and os.access(file,os.X_OK): return file
    raise RuntimeError('Teum 수집기를 찾지 못했습니다. Teum 앱을 설치해 주세요.')

def refresh(force=False):
    """Only the native read-only collector touches credentials. No GUI/settings writes."""
    DATA.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (DATA/'cli-refresh.lock').open('a+') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return {'in_progress':True}
        previous = read_json(DATA/'cli-readings.json',{})
        if not force and time.time()-previous.get('attemptedAt',0) < 60: return {'reused':True}
        result = subprocess.run([str(native_binary()),'--collect-json'],capture_output=True,text=True,timeout=125)
        if result.returncode: raise RuntimeError('Teum 수집기가 정상 종료되지 않았습니다. 기존 값은 유지합니다.')
        try: collected = json.loads(result.stdout)
        except ValueError: raise RuntimeError('수집기 응답을 해석하지 못했습니다. 기존 값은 유지합니다.')
        if collected.get('schemaVersion') != 1 or not isinstance(collected.get('snapshots'),dict): raise RuntimeError('지원하지 않는 수집기 응답입니다.')
        snapshots = previous.get('snapshots',{})
        for key,value in collected['snapshots'].items():
            if isinstance(value,dict) and (key in stream_names() or (isinstance(key,str) and key.startswith("codex-"))): snapshots[key] = value
        collected['snapshots'] = snapshots
        atomic_json(DATA/'cli-readings.json',collected)
        return {'updated':len(collected['snapshots']),'errors':collected.get('errors',{})}

def number(value):
    return isinstance(value,(float,int)) and not isinstance(value,bool) and math.isfinite(value)

def status(now=None):
    now = time.time() if now is None else now
    p = policy();gui = read_json(DATA/'readings.json',{});cli = read_json(DATA/'cli-readings.json',{})
    settings = read_json(DATA/'settings.json',{});display = {s['id']:s for s in settings.get('streams',[]) if isinstance(s,dict) and s.get('id') in stream_names()}
    result = []
    for key,name in stream_names(active=True).items():
        choices = [x for x in [gui.get(key),cli.get('snapshots',{}).get(key)] if isinstance(x,dict)]
        snapshot = max(choices,key=lambda x:x.get('fetchedAt',0)) if choices else {}
        disconnected = display.get(key,{}).get('connected') is False
        if disconnected: snapshot = {}
        fetched = snapshot.get('fetchedAt');valid_time = number(fetched) and -60 <= now-fetched <= p['max_age_seconds']
        attempt = cli.get('attemptedAt',0)
        error = cli.get('errors',{}).get(key) if attempt > (fetched or 0) else None
        if disconnected: error = 'Teum 연결 해제됨'
        windows = []
        for w in snapshot.get('windows',[]):
            used = w.get('usedPercent');reset = w.get('resetsAt')
            valid = number(used) and 0 <= used <= 100
            expired = number(reset) and reset <= now and (fetched or 0) < reset
            windows.append({'id':w.get('id',w.get('title','')),'title':w.get('title',''),'scope':w.get('scope'),'seconds':w.get('windowSeconds'),'remaining_percent':100-used if valid else None,'used_percent':used if valid else None,'reset_at':reset,'reset_in_seconds':max(0,reset-now) if number(reset) else None,'expired':expired,'extra':bool(w.get('extra') or w.get('credit')),'in_use':bool(w.get('inUse'))})
        result.append({'id':key,'name':display.get(key,{}).get('name',name),'fetched_at':fetched,'age_seconds':max(0,now-fetched) if number(fetched) else None,'fresh':bool(valid_time and not error),'error':error,'plan':snapshot.get('planName'),'warnings_enabled':display.get(key,{}).get('warns',True),'visible_in_app':display.get(key,{}).get('visible',True),'windows':windows})
    return {'schema_version':1,'generated_at':now,'streams':result,'policy':p}

def default_model(host,codex_home=None):
    home = Path.home()
    if host == 'claude': return read_json(home/'.claude/settings.json',{}).get('model','opus')
    if host == 'agy': return read_json(home/'.gemini/antigravity-cli/settings.json',{}).get('model','gemini-4-argon-medium')
    if host == 'kiro': return read_json(home/'.kiro/settings/cli.json',{}).get('chat.defaultModel','auto')
    if host == 'codex':
        file = Path(codex_home or os.environ.get('CODEX_HOME',str(home/'.codex')))/'config.toml'
        try:
            m = re.search(r'^model\s*=\s*"([^"]+)"',file.read_text(),re.M)
            if m: return m.group(1)
        except OSError: pass
    return None

def resolve_stream(host, model=None, profile=None, explicit=None):
    if explicit:
        if explicit not in stream_names(): raise ValueError('알 수 없는 스트림: '+explicit)
        return explicit
    if host == 'auto':
        host = os.environ.get('TEUM_HOST')
        if not host:
            if os.environ.get('KIRO_SESSION_ID'): host = 'kiro'
            elif os.environ.get('CLAUDE_CODE_SESSION_ID'): host = 'claude'
            elif os.environ.get('CODEX_HOME') or os.environ.get('CODEX_THREAD_ID'): host = 'codex'
        if not host: raise ValueError('--host claude|codex|agy|kiro 또는 --stream을 지정해 주세요.')
    if host == 'codex':
        profile = profile or os.environ.get('TEUM_PROFILE')
        if not profile:
            name = Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex'))).name
            profile = 'default' if name == '.codex' else name[7:] if name.startswith('.codex-') else None
        if not profile or profile in ['.','..'] or any(x in profile for x in ['/',chr(92),chr(0)]): raise ValueError('올바른 Codex 프로필 이름을 지정해 주세요.')
        return 'codex' if profile == 'default' else 'codex-'+profile
    if host == 'agy':
        m = (model or os.environ.get('TEUM_MODEL') or default_model(host) or '').lower()
        if any(s in m for s in ['claude','opus','sonnet','fable','gpt']): return 'agy-claude'
        if any(s in m for s in ['gemini','argon','flash']): return 'agy-general'
        raise ValueError('AGY의 모델 그룹을 판단하지 못했습니다. --model 또는 --stream을 지정해 주세요.')
    if host in ['claude','kiro','grok']: return host
    raise ValueError('지원하지 않는 호스트입니다.')

def model_family(model):
    return next((x for x in ['fable','opus','sonnet','haiku','argon','flash','luna'] if x in (model or '').lower()),None)

def model_weight(model):
    m = (model or '').lower()
    if any(x in m for x in ['haiku','luna','flash']): return 1
    if 'sonnet' in m: return 2
    if any(x in m for x in ['opus','fable','astra']): return 5
    return 3

def assess(report,stream_id,model=None):
    stream = next((s for s in report['streams'] if s['id'] == stream_id),None)
    if not stream: raise ValueError('스트림을 찾지 못했습니다.')
    p = dict(report['policy']);p.update(p.get('streams',{}).get(stream_id,{}))
    family = model_family(model)
    windows = [w for w in stream['windows'] if not w['extra'] and (not w['scope'] or stream_id.startswith('agy-') or stream_id=='grok' or (family and family in w['scope'].lower()))]
    known = [w for w in windows if w['remaining_percent'] is not None]
    reliable = stream['fresh'] and bool(known) and all(not w['expired'] for w in windows)
    minimum = min((w['remaining_percent'] for w in known),default=None)
    limiting = min(known,key=lambda w:w['remaining_percent']) if known else None
    if not reliable: stage = 'unknown'
    elif minimum <= p['stop_at']: stage = 'pause'
    elif minimum <= p['critical_below']: stage = 'critical'
    elif minimum <= p['conserve_below']: stage = 'conserve'
    else: stage = 'normal'
    group = 'codex' if stream_id.startswith('codex') else stream_id
    choice = p['models'].get(group,{}).get(stage)
    if model and choice and model_weight(model) < model_weight(choice): choice = model
    if stage in ['pause','unknown','normal']: choice = None
    delay = 8 if stage == 'critical' else 2 if stage == 'conserve' else 0
    scope = limiting.get('scope') if limiting else None
    reset = limiting.get('reset_at') if limiting else None
    message = {'unknown':'값이 없거나 오래됐습니다. 확인 전 자동 제어를 결정하지 마세요.','pause':'현재 한도가 소진됐습니다. 새 작업을 멈추고 진행 상태를 남기세요.','critical':'남은 한도가 적습니다. 새 병렬 작업을 줄이고 마무리·인계를 우선하세요.','conserve':'절약 모드입니다. 가벼운 모델과 순차 실행을 사용하고 불필요한 반복을 줄이세요.','normal':'일반 모드입니다.'}[stage]
    return {'schema_version':1,'stream':stream_id,'model':model,'stage':stage,'fresh':reliable,'remaining_percent':minimum,'limiting_window':limiting['id'] if limiting else None,'limiting_scope':scope,'reset_at':reset,'recommended_model':choice,'auto_switch':bool(p['auto_switch']),'max_parallel':1 if stage != 'normal' else 2,'launch_delay_seconds':delay,'poll_seconds':p['poll_seconds'],'advice':message,'enforcement':{'native_session':'hook_guidance','teum_cli_run':'launch_gate_and_owned_process_monitor'},'warning_exclusions_affect_budget':False}

def summary(b):
    left = '미확인' if b['remaining_percent'] is None else ('%.1f%%'%b['remaining_percent'])
    msg = 'Teum [%s] %s · 잔여 %s · %s'%(b['stream'],b['stage'],left,b['advice'])
    if b['recommended_model']: msg += ' 모델 후보: '+b['recommended_model']+'.'
    if b['stage'] != 'normal': msg += ' 동시 실행 최대 %d, 새 실행 간격 %d초.'%(b['max_parallel'],b['launch_delay_seconds'])
    if b['reset_at']: msg += ' 리셋 '+dt.datetime.fromtimestamp(b['reset_at']).astimezone().isoformat(timespec='minutes')+'.'
    return msg

def emit_hook(host,event,text):
    if host == 'agy': out = {'injectSteps':[{'ephemeralMessage':text}]} if text else {}
    elif host == 'kiro':
        if text: print(text)
        return
    elif text: out = {'hookSpecificOutput':{'hookEventName':event,'additionalContext':text}}
    else: out = {}
    print(json.dumps(out,ensure_ascii=False))

def session_id(explicit=None):
    value = explicit or next((os.environ.get(k) for k in ['TEUM_SESSION_ID','CODEX_THREAD_ID','CLAUDE_SESSION_ID','CLAUDE_CODE_SESSION_ID','KIRO_SESSION_ID'] if os.environ.get(k)),None)
    if not value or value == 'unknown' or len(value)>256: raise ValueError('현재 세션 ID를 --session 또는 TEUM_SESSION_ID로 지정해 주세요.')
    return value

@contextlib.contextmanager
def watch_state():
    DATA.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd = os.open(str(DATA/'session-watches.lock'),os.O_RDWR|os.O_CREAT,0o600)
    with os.fdopen(fd,'a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        state = read_json(DATA/'session-watches.json',{'schema_version':1,'rules':[]})
        now = time.time()
        for rule in state['rules']:
            if rule['state']=='armed' and rule['expires_at']<=now: rule.update(state='expired',finished_at=now)
        state['rules'] = [r for r in state['rules'] if r.get('finished_at',now)>now-7*86400]
        yield state
        atomic_json(DATA/'session-watches.json',state)

def check_watches(host,session,report=None):
    if not session or session=='unknown': return []
    report = status() if report is None else report
    events = [];now = report['generated_at']
    with watch_state() as state:
        for rule in state['rules']:
            if rule['state']!='armed' or rule['host']!=host or rule['session']!=session: continue
            stream = next((s for s in report['streams'] if s['id']==rule['stream']),None)
            if not stream or not stream['fresh']: continue
            family = model_family(rule.get('model'))
            windows = [w for w in stream['windows'] if not w['extra'] and not w['expired'] and w['remaining_percent'] is not None and (not w['scope'] or rule['stream'].startswith('agy-') or rule['stream']=='grok' or (family and family in w['scope'].lower()))]
            choice = rule['window']
            if choice=='weekly': windows = [w for w in windows if w['seconds'] and 6*86400<=w['seconds']<=8*86400]
            elif choice=='short': windows = [w for w in windows if w['seconds'] and w['seconds']<86400]
            elif choice!='auto': windows = [w for w in windows if w['id']==choice]
            limiting = min(windows,key=lambda w:w['remaining_percent'],default=None)
            if limiting is None or limiting['remaining_percent']>rule['below']: continue
            event = {'id':rule['id'],'stream':rule['stream'],'remaining_percent':limiting['remaining_percent'],'window':limiting['id'],'threshold':rule['below'],'message':rule['message'],'at':now}
            events.append(event);rule.update(state='delivered',finished_at=now,event=event)
    return events

def watch_text(events):
    return '\n'.join('Teum 일회성 세션 알림 [%s]: %s 잔여 %.1f%% ≤ %.1f%%. 이번 세션에서 합의한 대응: %s 이 조건의 알림은 전달을 마쳤습니다.'%(e['id'][:8],e['stream'],e['remaining_percent'],e['threshold'],e['message']) for e in events)

def watches(args):
    if args.action=='add':
        session = session_id(args.session);stream = resolve_stream(args.host,args.model,args.profile,args.stream)
        host = args.host if args.host!='auto' else ('codex' if stream.startswith('codex') else 'agy' if stream.startswith('agy') else stream)
        if not number(args.below) or not 0<=args.below<=100: raise ValueError('--below는 0~100 사이여야 합니다.')
        if not number(args.hours) or not 0<args.hours<=24: raise ValueError('--hours는 0 초과 24 이하여야 합니다.')
        if not args.message or len(args.message)>1000: raise ValueError('--message에 세션에서 합의한 대응을 1~1000자로 적어 주세요.')
        rule = {'id':uuid.uuid4().hex,'host':host,'session':session,'stream':stream,'model':args.model,'window':args.window,'below':args.below,'message':args.message,'created_at':time.time(),'expires_at':time.time()+args.hours*3600,'state':'armed'}
        with watch_state() as state: state['rules'].append(rule)
        result = rule
    elif args.action=='check':
        if args.refresh: refresh()
        session = session_id(args.session)
        if args.host=='auto': raise ValueError('check에는 --host를 지정해 주세요.')
        result = {'events':check_watches(args.host,session),'delivery':'이 명령 또는 호스트 훅이 실행되는 시점에 한 번 전달'}
    else:
        with watch_state() as state:
            if args.action=='cancel':
                if not args.id: raise ValueError('취소할 --id를 지정해 주세요.')
                found = next((r for r in state['rules'] if r['id']==args.id),None)
                if not found: raise ValueError('해당 세션 알림을 찾지 못했습니다.')
                if found['state']=='armed': found.update(state='cancelled',finished_at=time.time())
                result = found
            else: result = [r for r in state['rules'] if (args.all or r['state']=='armed') and (not args.session or r['session']==args.session)]
    print(json.dumps(result,ensure_ascii=False,indent=2) if args.json else watch_text(result['events']) if args.action=='check' else json.dumps(result,ensure_ascii=False,indent=2))
    return 0

def hook(args):
    try: data = json.loads(sys.stdin.read() or '{}')
    except ValueError: data = {}
    if not isinstance(data,dict): data = {}
    model = data.get('model') or data.get('modelId') or data.get('model_id') or os.environ.get('TEUM_MODEL')
    session = str(data.get('session_id') or data.get('conversationId') or data.get('sessionId') or os.environ.get('KIRO_SESSION_ID') or 'unknown')
    stream = resolve_stream(args.host,model,args.profile)
    events = check_watches(args.host,session)
    alert = watch_text(events)
    key = hashlib.sha256((args.host+':'+stream+':'+session).encode()).hexdigest()
    statefile = DATA/'hook-state'/(key+'.json');last = read_json(statefile,{})
    now = time.time();p = policy()
    if args.event.lower() not in ['sessionstart','agentspawn'] and now-last.get('at',0) < p['poll_seconds']:
        emit_hook(args.host,args.event,alert);return 0
    b = assess(status(now),stream,model)
    text = summary(b)
    if alert: text = alert+'\n'+text
    text += ' 필요할 때 teum-cli budget --host '+args.host+' --json으로 다시 확인하세요. UI 경고 제외는 사용량 정책과 별개입니다.'
    if b['recommended_model']: text += ' 현재 세션 모델은 실제 지원 경로로만 바꾸고, 새 작업은 teum-cli run으로 실행하세요.'
    atomic_json(statefile,{'at':now,'stage':b['stage'],'stream':stream})
    emit_hook(args.host,args.event,text)
    return 0

def binary(host):
    name = {'claude':'claude','agy':'agy','kiro':'kiro-cli','codex':'codex'}[host]
    found = shutil.which(name)
    if found: return found
    for directory in [Path.home()/'.local/bin',Path('/opt/homebrew/bin'),Path('/usr/local/bin')]:
        file = directory/name
        if file.is_file() and os.access(file,os.X_OK): return str(file)
    raise RuntimeError(host+' 실행 파일을 찾지 못했습니다. PATH를 확인하세요.')

def build_command(host,prompt,model,stage,extra):
    effort = 'low' if stage == 'critical' else 'medium' if stage == 'conserve' else None
    cmd = [binary(host)]
    if host == 'codex':
        cmd += ['exec']
        if model: cmd += ['--model',model]
        if effort: cmd += ['-c','model_reasoning_effort='+json.dumps(effort)]
        cmd += extra+[prompt]
    elif host == 'kiro':
        cmd += ['chat','--no-interactive']
        if model: cmd += ['--model',model]
        if effort: cmd += ['--effort',effort]
        cmd += extra+[prompt]
    else:
        cmd += ['-p',prompt]
        if model: cmd += ['--model',model]
        if host == 'claude' and effort: cmd += ['--effort',effort]
        cmd += extra
    return cmd

def run(args):
    model = args.model or default_model(args.host)
    stream = resolve_stream(args.host,model,args.profile,args.stream)
    if args.host == 'codex' and not args.model:
        model = default_model('codex',Path.home()/('.codex' if stream=='codex' else '.codex-'+stream.split('-',1)[1]))
    report = status();b = assess(report,stream,model)
    if args.refresh or (not b['fresh'] and not args.no_refresh): refresh();b = assess(status(),stream,model)
    selected = b['recommended_model'] if b['auto_switch'] and b['recommended_model'] else model
    cmd = build_command(args.host,args.prompt,selected,b['stage'],args.extra)
    plan = {'budget':b,'selected_model':selected,'command':cmd,'will_run':b['stage'] not in ['pause','unknown'],'changes_global_model':False}
    if args.dry_run: print(json.dumps(plan,ensure_ascii=False,indent=2));return 0
    if not plan['will_run']: print(summary(b),file=sys.stderr);return 75 if b['stage']=='pause' else 78
    locks = DATA/'run-slots';locks.mkdir(parents=True,exist_ok=True,mode=0o700)
    end = time.monotonic()+args.queue_timeout;slot = None
    while slot is None:
        b = assess(status(),stream,model)
        if b['stage'] in ['pause','unknown']: print(summary(b),file=sys.stderr);return 75 if b['stage']=='pause' else 78
        for i in range(b['max_parallel']):
            candidate = (locks/(stream+'-'+str(i)+'.lock')).open('a+')
            try: fcntl.flock(candidate,fcntl.LOCK_EX|fcntl.LOCK_NB);slot = candidate;break
            except BlockingIOError: candidate.close()
        if slot is None:
            if time.monotonic()>=end: print('Teum: 동시 실행 대기 시간이 끝났습니다.',file=sys.stderr);return 75
            time.sleep(min(1,max(0,end-time.monotonic())))
    with slot:
        if b['launch_delay_seconds']: time.sleep(b['launch_delay_seconds'])
        # Re-evaluate after waiting, so a queued job cannot spend newly exhausted quota.
        b = assess(status(),stream,model)
        if b['stage'] in ['pause','unknown']: print(summary(b),file=sys.stderr);return 75 if b['stage']=='pause' else 78
        selected = b['recommended_model'] if b['auto_switch'] and b['recommended_model'] else model
        cmd = build_command(args.host,args.prompt,selected,b['stage'],args.extra)
        env = dict(os.environ,TEUM_HOST=args.host,TEUM_MODEL=selected or '',TEUM_STREAM=stream)
        if args.host == 'codex': env['CODEX_HOME'] = str(Path.home()/('.codex' if stream=='codex' else '.codex-'+stream.split('-',1)[1]))
        print(summary(b)+' 실행 모델: '+str(selected),file=sys.stderr)
        proc = subprocess.Popen(cmd,env=env,start_new_session=True)
        last_check = time.monotonic();interrupted = False
        try:
            while proc.poll() is None:
                time.sleep(0.25)
                if time.monotonic()-last_check >= b['poll_seconds']:
                    current = assess(status(),stream,selected);last_check = time.monotonic()
                    if current['stage']=='pause' and not interrupted:
                        print('Teum: 새로 확인된 한도가 소진되어 이 CLI가 시작한 작업에 중단 신호를 보냅니다.',file=sys.stderr)
                        os.killpg(proc.pid,signal.SIGINT);interrupted = True
            return 75 if interrupted else proc.returncode
        except KeyboardInterrupt:
            with contextlib.suppress(ProcessLookupError): os.killpg(proc.pid,signal.SIGINT)
            with contextlib.suppress(subprocess.TimeoutExpired): proc.wait(timeout=10)
            return 130

def parser():
    p = argparse.ArgumentParser(prog='teum-cli',description='Teum의 실제 한도 조회, AI 예산 판단, 환경별 훅과 모델 조절 실행')
    p.add_argument('--version',action='version',version='teum-cli 1.0')
    commands = p.add_subparsers(dest='command',required=True)
    def target(sub):
        sub.add_argument('--host',choices=HOSTS+['grok','auto'],default='auto');sub.add_argument('--profile');sub.add_argument('--stream',choices=list(stream_names()));sub.add_argument('--model')
    s = commands.add_parser('status',help='연결된 계정 사용량 조회');s.add_argument('--json',action='store_true');s.add_argument('--refresh',action='store_true')
    for name in ['budget','gate']:
        s = commands.add_parser(name,help='해당 세션에만 적용할 잔여량·동작 권고');target(s);s.add_argument('--json',action='store_true');s.add_argument('--refresh',action='store_true')
    commands.add_parser('refresh',help='추론 없이 실제 사용량 새로 읽기')
    s = commands.add_parser('plan',help='Teum의 실제 주간 한도로 계산한 계정별 배분 계획');s.add_argument('--json',action='store_true')
    s = commands.add_parser('watch',help='현재 세션과 합의한 일회성 잔여량 알림')
    s.add_argument('action',choices=['add','list','check','cancel']);target(s)
    s.add_argument('--session');s.add_argument('--id');s.add_argument('--below',type=float)
    s.add_argument('--window',default='auto',help='auto / short / weekly / 정확한 한도 ID')
    s.add_argument('--message');s.add_argument('--hours',type=float,default=12)
    s.add_argument('--json',action='store_true');s.add_argument('--all',action='store_true');s.add_argument('--refresh',action='store_true')
    commands.add_parser('doctor',help='설치·데이터·연결 상태')
    s = commands.add_parser('hook',help='호스트별 캐시 기반 문맥 주입');s.add_argument('--host',required=True,choices=HOSTS);s.add_argument('--event',required=True);s.add_argument('--profile')
    s = commands.add_parser('run',help='예산에 맞춘 단발 AI 작업 실행');target(s);s.set_defaults(host=None);s.add_argument('--prompt',required=True);s.add_argument('--dry-run',action='store_true');s.add_argument('--refresh',action='store_true');s.add_argument('--no-refresh',action='store_true');s.add_argument('--queue-timeout',type=float,default=300);s.add_argument('extra',nargs=argparse.REMAINDER)
    s = commands.add_parser('policy',help='자동 조절 기준');s.add_argument('action',choices=['show','set'],nargs='?',default='show');s.add_argument('--stream',choices=list(stream_names()));s.add_argument('--conserve',type=float);s.add_argument('--critical',type=float);s.add_argument('--stop-at',type=float);s.add_argument('--auto-switch',choices=['on','off'])
    return p

def token_text(n):
    n = float(n)
    for size,suffix in ((1e9,'B'),(1e6,'M'),(1e3,'K')):
        if n >= size: return ('%.2f' if suffix == 'B' else '%.1f')%(n/size)+suffix
    return str(int(n))

def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command=='watch': return watches(args)
        if args.command == 'plan':
            proc = subprocess.run([str(native_binary()),'--plan-json','--plan-data',str(DATA)],capture_output=True,text=True,timeout=20,check=True)
            result = json.loads(proc.stdout)
            if args.json: print(json.dumps(result,ensure_ascii=False,indent=2))
            else:
                chosen = result.get('recommendedStream')
                print('다음 추천: '+next((a['name'] for a in result['accounts'] if a['id']==chosen),'대기 / 최신 한도 확인'))
                today = {x['id']:x['percentagePoints'] for x in (result.get('days') or [{}])[0].get('targets',[])}
                for a in result['accounts']:
                    target = '오늘 배분 %.1f%%p'%today[a['id']] if a['id'] in today else '균등 기준 %.1f%%p/일'%a['targetPercentagePointsPerDay']
                    size = a.get('estimatedWeightedTokensPerPercentagePoint')
                    print('%s · 주간 %.1f%% 남음 · %s · 리셋 %s%s'%(a['name'],a['remainingPercent'],target,a['resetAt'],' · 1%%p ≈ %s 환산 토큰'%token_text(size) if size else ''))
                if result.get('basis') == 'work': print('일하는 양(추정 환산 토큰) 기준 권고입니다. 추정이 없는 계정은 %p 순서로 뒤에 두며 자동 전환은 하지 않습니다.')
                else: print('계정별 %p 기준의 권고입니다. 1%p 크기는 참고로만 보여 주며 자동 전환은 하지 않습니다.')
            return 0
        if args.command == 'hook': return hook(args)
        if args.command == 'refresh': print(json.dumps(refresh(force=True),ensure_ascii=False,indent=2));return 0
        if args.command == 'policy':
            p = policy()
            if args.action == 'set':
                target = p.setdefault('streams',{}).setdefault(args.stream,{}) if args.stream else p
                for key,field in [('conserve_below','conserve'),('critical_below','critical'),('stop_at','stop_at')]:
                    value = getattr(args,field)
                    if value is not None: target[key] = value
                if args.auto_switch is not None: target['auto_switch'] = args.auto_switch=='on'
                validate_policy(p);atomic_json(DATA/'policy.json',p)
            print(json.dumps(p,ensure_ascii=False,indent=2));return 0
        if args.command == 'doctor':
            print(json.dumps({'schema_version':1,'data_directory':str(DATA),'collector':str(native_binary()),'streams':[{k:s[k] for k in ['id','fresh','age_seconds','error']} for s in status()['streams']],'integration_manifest':read_json(DATA/'integration.json',{})},ensure_ascii=False,indent=2));return 0
        if args.command == 'run':
            if args.host not in HOSTS: raise ValueError('run은 claude|codex|agy|kiro를 지원합니다. Grok은 현재 사용량 조회와 gate만 지원합니다.')
            if args.extra[:1]==['--']: args.extra = args.extra[1:]
            if any(x in ['--model','-m','--settings'] or x.startswith('--model=') for x in args.extra): raise ValueError('모델은 teum-cli run의 --model로 지정해 주세요.')
            return run(args)
        if getattr(args,'refresh',False): refresh()
        report = status()
        if args.command == 'status':
            if args.json: print(json.dumps(report,ensure_ascii=False,indent=2))
            else:
                for s in report['streams']:
                    windows = [w for w in s['windows'] if not w['extra']]
                    values = ', '.join('%s: %s'%(w['scope'] or w['title'],'미확인' if w['remaining_percent'] is None else '%.1f%% 남음'%w['remaining_percent']) for w in windows)
                    print('%s [%s] %s%s'%(s['name'],s['id'],values or '값 없음',' · 이전 값' if not s['fresh'] else ''))
            return 0
        model = args.model or os.environ.get('TEUM_MODEL')
        stream = resolve_stream(args.host,model,args.profile,args.stream)
        result = assess(report,stream,model)
        print(json.dumps(result,ensure_ascii=False,indent=2) if args.json else summary(result))
        return (75 if result['stage']=='pause' else 78 if result['stage']=='unknown' else 0) if args.command=='gate' else 0
    except (ValueError,RuntimeError,OSError,subprocess.SubprocessError) as exc:
        if args.command=='hook':
            emit_hook(args.host,args.event,'Teum 사용량을 확인하지 못했습니다. 자동 차단 없이 진행하며 teum-cli doctor로 확인하세요.');return 0
        print('Teum: '+str(exc),file=sys.stderr);return 2

if __name__ == '__main__': raise SystemExit(main())
