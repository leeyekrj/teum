import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('teum_cli',Path(__file__).parents[1]/'teum_cli.py')
t = importlib.util.module_from_spec(spec);spec.loader.exec_module(t)

class QuotaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name);self.patch = patch.object(t,'DATA',self.data);self.patch.start();self.addCleanup(self.patch.stop)
        self.env = patch.dict(os.environ,{},clear=True);self.env.start();self.addCleanup(self.env.stop)
        self.now = time.time()
        self.fixtures = {key:{'fetchedAt':self.now,'windows':[self.window('session',10,18000),self.window('weekly',20,604800)]} for key in t.NAMES}
        self.save()
    def window(self,name,used,seconds=None,scope=None,extra=False):
        return dict(id=name,title=name,usedPercent=used,windowSeconds=seconds,scope=scope,extra=extra,resetsAt=self.now+3600)
    def save(self):t.atomic_json(self.data/'readings.json',self.fixtures)
    def budget(self,key='claude',model=None):return t.assess(t.status(self.now),key,model)
    def add_watch(self,session='one',stream='claude',window='weekly',below=25):
        args=t.parser().parse_args(['watch','add','--host','claude','--stream',stream,'--session',session,'--window',window,'--below',str(below),'--message','인계하고 멈추기','--json'])
        output=io.StringIO()
        with contextlib.redirect_stdout(output):self.assertEqual(t.watches(args),0)
        return json.loads(output.getvalue())
    def test_session_watch_is_isolated_and_one_shot(self):
        rule=self.add_watch();self.fixtures['claude']['windows'][1]['usedPercent']=90;self.save()
        self.assertEqual(t.check_watches('claude','other'),[])
        self.assertEqual(t.check_watches('codex','one'),[])
        events=t.check_watches('claude','one')
        self.assertEqual(events[0]['id'],rule['id']);self.assertEqual(events[0]['remaining_percent'],10)
        self.assertEqual(t.check_watches('claude','one'),[])
    def test_session_watch_can_choose_weekly_instead_of_short(self):
        self.add_watch();self.fixtures['claude']['windows'][0]['usedPercent']=100;self.save()
        self.assertEqual(t.check_watches('claude','one'),[])
    def test_session_watch_cannot_fire_on_old_or_expired_data(self):
        self.add_watch();self.fixtures['claude']['windows'][1]['usedPercent']=100
        self.fixtures['claude']['fetchedAt']=time.time()-700;self.save()
        self.assertEqual(t.check_watches('claude','one'),[])
        self.fixtures['claude']['fetchedAt']=time.time()-10;self.fixtures['claude']['windows'][1]['resetsAt']=time.time()-5;self.save()
        self.assertEqual(t.check_watches('claude','one'),[])
    def test_expired_and_cancelled_watches_do_not_fire(self):
        rule=self.add_watch();second=self.add_watch(session='two')
        with t.watch_state() as state:state['rules'][0]['expires_at']=time.time()-1
        args=t.parser().parse_args(['watch','cancel','--id',second['id']])
        with contextlib.redirect_stdout(io.StringIO()):t.watches(args)
        self.fixtures['claude']['windows'][1]['usedPercent']=100;self.save()
        self.assertEqual(t.check_watches('claude','one'),[]);self.assertEqual(t.check_watches('claude','two'),[])
        states={r['id']:r['state'] for r in t.read_json(self.data/'session-watches.json')['rules']}
        self.assertEqual(states[rule['id']],'expired');self.assertEqual(states[second['id']],'cancelled')
    def test_watch_requires_session_and_finite_condition(self):
        base=['watch','add','--host','claude','--message','멈추기']
        for extra in [['--below','10'],['--session','x','--below','nan'],['--session','x','--below','101'],['--session','x','--below','10','--hours','100']]:
            with contextlib.redirect_stderr(io.StringIO()):self.assertEqual(t.main(base+extra),2)
    def test_watch_threshold_is_inclusive_and_ignores_ui_exclusions(self):
        self.add_watch(below=20);t.atomic_json(self.data/'settings.json',{'streams':[{'id':'claude','warns':False,'visible':False}]})
        self.fixtures['claude']['windows'][1]['usedPercent']=80;self.save()
        self.assertEqual(t.check_watches('claude','one')[0]['remaining_percent'],20)
    def test_watch_specific_window_and_model_scope(self):
        self.add_watch(window='fable',below=50)
        self.fixtures['claude']['windows'].append(self.window('fable',100,604800,'Fable'));self.save()
        self.assertEqual(t.check_watches('claude','one'),[])
        with t.watch_state() as state:state['rules'][0]['model']='claude-fable-5'
        self.assertEqual(t.check_watches('claude','one')[0]['window'],'fable')
    def test_session_alert_bypasses_normal_hook_throttle(self):
        self.add_watch();self.fixtures['claude']['windows'][1]['usedPercent']=100;self.save()
        key=t.hashlib.sha256(b'claude:claude:one').hexdigest()
        t.atomic_json(self.data/'hook-state'/(key+'.json'),{'at':time.time()})
        args=t.parser().parse_args(['hook','--host','claude','--event','PreToolUse'])
        out=io.StringIO()
        with patch.object(t.sys,'stdin',io.StringIO('{"session_id":"one"}')),contextlib.redirect_stdout(out):t.hook(args)
        self.assertIn('일회성 세션 알림',out.getvalue());self.assertIn('인계하고 멈추기',out.getvalue())
        self.assertEqual(t.check_watches('claude','one'),[])
    def test_plan_bridge_uses_native_cache_and_honors_data_directory(self):
        payload = {'schemaVersion':1,'recommendedStream':'codex','accounts':[{'id':'codex','name':'코덱스','remainingPercent':50,'targetPercentagePointsPerDay':20,'resetAt':'2026-11-01T00:00:00Z'}],'days':[]}
        completed = t.subprocess.CompletedProcess([],0,stdout=json.dumps(payload),stderr='')
        out = io.StringIO()
        with patch.object(t,'native_binary',return_value=Path('/tmp/teum-fixture')),patch.object(t.subprocess,'run',return_value=completed) as call,contextlib.redirect_stdout(out):
            self.assertEqual(t.main(['plan','--json']),0)
        self.assertEqual(json.loads(out.getvalue()),payload)
        self.assertEqual(call.call_args.args[0],['/tmp/teum-fixture','--plan-json','--plan-data',str(self.data)])
        self.assertTrue(call.call_args.kwargs['check'])
        self.assertEqual(call.call_args.kwargs['timeout'],20)
    def test_plan_empty_state_is_an_advisory_not_an_execution(self):
        completed = t.subprocess.CompletedProcess([],0,stdout=json.dumps({'schemaVersion':1,'recommendedStream':None,'accounts':[]}),stderr='')
        out = io.StringIO()
        with patch.object(t,'native_binary',return_value=Path('/tmp/teum-fixture')),patch.object(t.subprocess,'run',return_value=completed),contextlib.redirect_stdout(out):
            self.assertEqual(t.main(['plan']),0)
        self.assertIn('대기 / 최신 한도 확인',out.getvalue())
    def test_plan_text_shows_point_size_and_basis(self):
        payload = {'schemaVersion':1,'basis':'work','recommendedStream':'codex','accounts':[{'id':'codex','name':'코덱스','remainingPercent':50,'targetPercentagePointsPerDay':20,'resetAt':'2026-11-04T00:00:00Z','estimatedWeightedTokensPerPercentagePoint':2_000_000},{'id':'kiro','name':'키로','remainingPercent':70,'targetPercentagePointsPerDay':3,'resetAt':'2026-12-01T00:00:00Z','estimatedWeightedTokensPerPercentagePoint':None}],'days':[]}
        completed = t.subprocess.CompletedProcess([],0,stdout=json.dumps(payload),stderr='')
        out = io.StringIO()
        with patch.object(t,'native_binary',return_value=Path('/tmp/teum-fixture')),patch.object(t.subprocess,'run',return_value=completed),contextlib.redirect_stdout(out):
            self.assertEqual(t.main(['plan']),0)
        text = out.getvalue()
        self.assertIn('1%p ≈ 2.0M 환산 토큰',text);self.assertIn('일하는 양(추정 환산 토큰) 기준',text)
        self.assertNotIn('키로 · 주간 70.0% 남음 · 균등 기준 3.0%p/일 · 리셋 2026-12-01T00:00:00Z · 1%p',text)
    def test_disconnected_cached_usage_is_unavailable(self):
        t.atomic_json(self.data/'settings.json',{'streams':[{'id':'claude','connected':False}]})
        row=next(s for s in t.status(self.now)['streams'] if s['id']=='claude')
        self.assertFalse(row['fresh']);self.assertEqual(row['windows'],[])
        self.assertEqual(self.budget()['stage'],'unknown')
    def test_single_configured_codex_profile_has_one_row(self):
        t.atomic_json(self.data/'settings.json',{'notchStyle':'mixed','streams':[{'id':'codex','source':'codex','name':'개인'}]})
        self.assertEqual([s['id'] for s in t.status(self.now)['streams']],['codex'])
    def test_custom_codex_profile_routing(self):
        t.atomic_json(self.data/'settings.json',{'notchStyle':'mixed','streams':[{'id':'codex-work','source':'codex','name':'업무'}]})
        self.fixtures['codex-work']=self.fixtures['codex'];self.save()
        self.assertEqual(t.resolve_stream('codex',profile='work'),'codex-work')
        self.assertEqual(next(s for s in t.status(self.now)['streams'] if s['id']=='codex-work')['name'],'업무')
        with patch.dict(os.environ,{'CODEX_HOME':str(Path.home()/'.codex-work')}):self.assertEqual(t.resolve_stream('codex'),'codex-work')
        self.assertEqual(t.assess(t.status(self.now),'codex-work')['stage'],'normal')
    def test_codex_profile_path_traversal_rejected(self):
        with self.assertRaises(ValueError):t.resolve_stream('codex',profile='../other')
    def test_custom_codex_run_reads_that_profiles_model(self):
        t.atomic_json(self.data/'settings.json',{'notchStyle':'mixed','streams':[{'id':'codex-work','source':'codex','name':'업무'}]})
        self.fixtures['codex-work']=self.fixtures['codex'];self.save()
        folder=self.data/'.codex-work';folder.mkdir();(folder/'config.toml').write_text('model = "work-model"\n')
        args=t.parser().parse_args(['run','--host','codex','--profile','work','--prompt','test','--dry-run','--no-refresh'])
        output=io.StringIO()
        with patch.object(t.Path,'home',return_value=self.data),patch.object(t,'binary',return_value='/codex'),contextlib.redirect_stdout(output):
            self.assertEqual(t.run(args),0)
        self.assertEqual(json.loads(output.getvalue())['selected_model'],'work-model')
    def test_cli_finds_host_on_path(self):
        with patch.object(t.shutil, 'which', return_value='/custom/bin/codex'):
            self.assertEqual(t.binary('codex'), '/custom/bin/codex')

    def test_bundled_collector_is_preferred(self):
        with tempfile.TemporaryDirectory() as directory:
            from pathlib import Path
            root = Path(directory)/'Contents/Resources'
            collector = root.parent/'MacOS/Teum'
            collector.parent.mkdir(parents=True)
            collector.write_text('#!/bin/sh\nexit 0\n')
            collector.chmod(0o755)
            with patch.object(t, 'ROOT', root), patch.dict(os.environ, {}, clear=True):
                self.assertEqual(t.native_binary(), collector)

    def test_normal(self):self.assertEqual(self.budget()['stage'],'normal')
    def test_remaining_not_used(self):self.assertEqual(self.budget()['remaining_percent'],80)
    def test_lowest_window_governs(self):
        self.fixtures['claude']['windows'][1]['usedPercent']=86;self.save();self.assertEqual(self.budget()['stage'],'conserve')
    def test_critical(self):
        self.fixtures['claude']['windows'][0]['usedPercent']=96;self.save();self.assertEqual(self.budget()['stage'],'critical')
    def test_exhausted_pause(self):
        self.fixtures['kiro']['windows'][0]['usedPercent']=100;self.save();self.assertEqual(self.budget('kiro')['stage'],'pause')
    def test_other_account_cannot_stop_current(self):
        self.fixtures['kiro']['windows'][0]['usedPercent']=100;self.save();self.assertEqual(self.budget('codex')['stage'],'normal')
    def test_zero_only_scoped_to_other_model(self):
        self.fixtures['claude']['windows'].append(self.window('fable',100,604800,'Fable'));self.save()
        self.assertEqual(self.budget(model='opus')['stage'],'normal');self.assertEqual(self.budget(model='claude-fable-5')['stage'],'pause')
    def test_scope_unknown_does_not_assume_model(self):
        self.fixtures['claude']['windows'].append(self.window('fable',100,604800,'Fable'));self.save();self.assertEqual(self.budget()['stage'],'normal')
    def test_extra_balance_not_limit(self):
        self.fixtures['claude']['windows'].append(self.window('bonus',100,None,extra=True));self.save();self.assertEqual(self.budget()['stage'],'normal')
    def test_old_data_unknown_not_pause(self):
        self.fixtures['claude'].update(fetchedAt=self.now-601);self.fixtures['claude']['windows'][0]['usedPercent']=100;self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_expired_reset_not_fresh_100(self):
        self.fixtures['claude']['fetchedAt']=self.now-60;self.fixtures['claude']['windows'][0]['resetsAt']=self.now-10;self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_fresh_server_after_reset_valid(self):
        self.fixtures['claude']['windows'][0]['resetsAt']=self.now-10;self.save();self.assertEqual(self.budget()['stage'],'normal')
    def test_missing_unknown(self):
        del self.fixtures['claude'];self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_nan_unknown(self):
        self.fixtures['claude']['windows']=[self.window('x',float('nan'))];self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_none_unknown(self):
        self.fixtures['claude']['windows']=[self.window('x',None)];self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_boolean_not_number(self):
        self.fixtures['claude']['windows']=[self.window('x',True)];self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_future_clock_unknown(self):
        self.fixtures['claude']['fetchedAt']=self.now+120;self.save();self.assertEqual(self.budget()['stage'],'unknown')
    def test_hide_warning_does_not_remove_budget(self):
        self.fixtures['claude']['windows'][0]['usedPercent']=100;self.save();t.atomic_json(self.data/'settings.json',{'streams':[{'id':'claude','visible':False,'warns':False}]});self.assertEqual(self.budget()['stage'],'pause')
    def test_cli_newer_overrides_gui(self):
        value=copy.deepcopy(self.fixtures['claude']);value['fetchedAt']=self.now+1;value['windows'][0]['usedPercent']=100
        t.atomic_json(self.data/'cli-readings.json',{'snapshots':{'claude':value}});self.assertEqual(self.budget()['stage'],'pause')
    def test_cli_error_not_fresh(self):
        t.atomic_json(self.data/'cli-readings.json',{'attemptedAt':self.now+1,'errors':{'claude':'offline'}});self.assertEqual(self.budget()['stage'],'unknown')
    def test_new_gui_clears_old_error(self):
        t.atomic_json(self.data/'cli-readings.json',{'attemptedAt':self.now-1,'errors':{'claude':'offline'}});self.assertEqual(self.budget()['stage'],'normal')
    def test_codex_profiles(self):
        self.assertEqual(t.resolve_stream('codex',profile='work'),'codex-work');self.assertEqual(t.resolve_stream('codex',profile='team'),'codex-team')
    def test_codex_home(self):
        with patch.dict(os.environ,{'CODEX_HOME':'/Users/test/.codex-work'}):self.assertEqual(t.resolve_stream('codex'),'codex-work')
    def test_unknown_profile_refused(self):
        with patch.dict(os.environ,{'CODEX_HOME':'/tmp/something'}):
            with self.assertRaises(ValueError):t.resolve_stream('codex')
    def test_agy_model_groups(self):
        self.assertEqual(t.resolve_stream('agy','claude-opus-5-5-high'),'agy-claude');self.assertEqual(t.resolve_stream('agy','gemini-4-argon-high'),'agy-general')
    def test_grok_read_route(self):
        self.assertEqual(t.resolve_stream('grok'),'grok')
    def test_grok_scoped_quota_is_account_usage(self):
        self.fixtures['grok']['windows']=[self.window('bot-week',92,604800,'Grok Bot')];self.save()
        self.assertEqual(self.budget('grok')['remaining_percent'],8)
        self.assertEqual(self.budget('grok')['stage'],'conserve')
    def test_grok_run_is_not_webhook_send(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(t.main(['run','--host','grok','--prompt','must not send']),2)
    def test_unknown_agy_model_refused(self):
        with self.assertRaises(ValueError):t.resolve_stream('agy','unknown-model')
    def test_no_automatic_host_guess(self):
        with self.assertRaises(ValueError):t.resolve_stream('auto')
    def test_cheap_model_not_upgraded(self):
        self.fixtures['claude']['windows'][0]['usedPercent']=86;self.save();self.assertEqual(self.budget(model='haiku')['recommended_model'],'haiku')
    def test_policy_validation(self):
        p=copy.deepcopy(t.DEFAULT_POLICY);p['critical_below']=40
        with self.assertRaises(ValueError):t.validate_policy(p)
    def test_stream_policy_only_changes_target(self):
        p=copy.deepcopy(t.DEFAULT_POLICY);p['streams']={'claude':{'conserve_below':90}};t.atomic_json(self.data/'policy.json',p)
        self.assertEqual(self.budget()['stage'],'conserve');self.assertEqual(self.budget('codex')['stage'],'normal')
    def test_policy_bad_write_does_not_destroy_previous(self):
        t.atomic_json(self.data/'policy.json',t.DEFAULT_POLICY)
        with contextlib.redirect_stderr(io.StringIO()):code=t.main(['policy','set','--critical','99'])
        self.assertEqual(code,2);self.assertEqual(t.read_json(self.data/'policy.json')['critical_below'],5)
    def test_private_atomic_file(self):
        self.assertEqual((self.data/'readings.json').stat().st_mode&0o777,0o600)
    def test_run_dry_no_inference(self):
        with patch.object(t,'binary',return_value='/fake/codex'),patch.object(t.subprocess,'Popen') as pop,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(t.main(['run','--host','codex','--model','gpt-6.1-sol','--prompt','test','--dry-run','--no-refresh']),0)
        self.assertTrue(json.loads(out.getvalue())['will_run']);pop.assert_not_called()
    def test_run_exhausted_never_launches(self):
        self.fixtures['kiro']['windows'][0]['usedPercent']=100;self.save()
        with patch.object(t,'binary',return_value='/fake/kiro'),patch.object(t.subprocess,'Popen') as pop,contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(t.main(['run','--host','kiro','--model','auto','--prompt','test','--no-refresh']),75)
        pop.assert_not_called()
    def test_hook_codex_schema(self):
        with patch('sys.stdin',io.StringIO('{"session_id":"x","model":"gpt-6.1-sol"}')),contextlib.redirect_stdout(io.StringIO()) as out:
            t.main(['hook','--host','codex','--event','SessionStart'])
        self.assertEqual(json.loads(out.getvalue())['hookSpecificOutput']['hookEventName'],'SessionStart')
    def test_hook_agy_schema(self):
        with patch('sys.stdin',io.StringIO('{"sessionId":"x","modelId":"gemini-4-argon-medium"}')),contextlib.redirect_stdout(io.StringIO()) as out:
            t.main(['hook','--host','agy','--event','PreInvocation'])
        self.assertIn('ephemeralMessage',json.loads(out.getvalue())['injectSteps'][0])
    def test_hook_rate_limit(self):
        payload='{"session_id":"limited","model":"gpt-6.1-sol"}'
        for _ in range(2):
            with patch('sys.stdin',io.StringIO(payload)),contextlib.redirect_stdout(io.StringIO()) as out:t.main(['hook','--host','codex','--event','PreToolUse'])
        self.assertEqual(json.loads(out.getvalue()),{})
    def test_hook_does_not_refresh_or_deny(self):
        self.fixtures['claude']['fetchedAt']=self.now-700;self.save()
        with patch.object(t,'refresh') as refresh,patch('sys.stdin',io.StringIO('{}')),contextlib.redirect_stdout(io.StringIO()) as out:t.main(['hook','--host','claude','--event','SessionStart'])
        result=json.loads(out.getvalue());self.assertNotIn('continue',result);self.assertNotIn('permissionDecision',result['hookSpecificOutput']);refresh.assert_not_called()

if __name__=='__main__':unittest.main()
