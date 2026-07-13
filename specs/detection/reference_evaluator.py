#!/usr/bin/env python3
from __future__ import annotations
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from datetime import date
import hashlib, json, sys

Q=Decimal('0.0001')
def D(v): return Decimal(str(v))
def q(v): return str(D(v).quantize(Q, rounding=ROUND_HALF_UP))
def canonical(obj): return json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def sha(obj): return hashlib.sha256(canonical(obj).encode()).hexdigest()
def blocked(code, input_obj):
    result={'outcome':'BLOCKED','blockers':[code],'metrics':{},'included_ids':[],'excluded_ids':[]}
    result['input_hash']=sha(input_obj); result['result_hash']=sha(result); return result
def finish(outcome, blockers, metrics, included, excluded, input_obj):
    result={'outcome':outcome,'blockers':blockers,'metrics':metrics,'included_ids':sorted(included),'excluded_ids':sorted(excluded)}
    result['input_hash']=sha(input_obj); result['result_hash']=sha(result); return result
def missing(obj,path):
    cur=obj
    for p in path.split('.'):
        if not isinstance(cur,dict) or p not in cur or cur[p] is None: return True
        cur=cur[p]
    return False

def eval_price(x):
    for p in ['target.id','target.unit_price','target.unit','target.category','target.vat_included','target.bundle_known','target.observed_at','comparables']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    t=x['target']
    if not t['bundle_known']: return blocked('TARGET_BUNDLE_UNKNOWN',x)
    if t['vat_included'] is None: return blocked('TARGET_VAT_UNKNOWN',x)
    seen=set(); included=[]; excluded=[]; vals=[]
    td=date.fromisoformat(t['observed_at'])
    for c in x['comparables']:
        cid=c.get('id','UNKNOWN')
        key=c.get('source_key',cid)
        ok=True
        if key in seen: ok=False
        seen.add(key)
        for field in ['unit_price','unit','category','vat_included','bundle_known','observed_at']:
            if c.get(field) is None: ok=False
        if ok and (c['unit']!=t['unit'] or c['category']!=t['category'] or c['vat_included']!=t['vat_included'] or not c['bundle_known']): ok=False
        if ok and abs((td-date.fromisoformat(c['observed_at'])).days)>365: ok=False
        if ok: included.append(cid); vals.append(D(c['unit_price']))
        else: excluded.append(cid)
    if len(vals)<8: return blocked('INSUFFICIENT_COMPARABLES',x)
    vals.sort(); n=len(vals); med=vals[n//2] if n%2 else (vals[n//2-1]+vals[n//2])/2
    ratio=D(t['unit_price'])/med
    return finish('SIGNAL' if ratio>=D(3) else 'NO_SIGNAL',[],{'target_unit_price':str(t['unit_price']),'median_unit_price':q(med),'ratio':q(ratio),'comparable_count':len(vals)},included,excluded,x)

def contract_groups(contracts):
    dedup={c['id']:c for c in contracts if c.get('id')}; return list(dedup.values())
def eval_split(x):
    for p in ['contracts','single_source_threshold','window_days']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    required=['agency_id','supplier_id','category','signed_at','amount','method']
    if any(any(c.get(f) is None for f in required) for c in cs): return blocked('REQUIRED_FIELD_MISSING',x)
    candidates=[c for c in cs if c['method']=='SINGLE_SOURCE' and D(c['amount'])<D(x['single_source_threshold']) and not c.get('legitimate_phase',False)]
    groups={}
    for c in candidates: groups.setdefault((c['agency_id'],c['supplier_id'],c['category']),[]).append(c)
    matched=[]
    for g in groups.values():
        g.sort(key=lambda c:c['signed_at']); span=(date.fromisoformat(g[-1]['signed_at'])-date.fromisoformat(g[0]['signed_at'])).days
        if len(g)>=3 and span<=int(x['window_days']) and sum(D(c['amount']) for c in g)>=D(x['single_source_threshold']): matched.extend(c['id'] for c in g)
    return finish('SIGNAL' if matched else 'NO_SIGNAL',[],{'matched_contract_count':len(set(matched)),'threshold':str(x['single_source_threshold'])},matched,[c['id'] for c in cs if c['id'] not in matched],x)

def eval_repeated(x):
    for p in ['contracts','window_days']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    req=['agency_id','supplier_id','category','signed_at','amount','method']
    if any(any(c.get(f) is None for f in req) for c in cs): return blocked('REQUIRED_FIELD_MISSING',x)
    groups={}
    for c in cs:
        if c['method']=='SINGLE_SOURCE': groups.setdefault((c['agency_id'],c['supplier_id'],c['category']),[]).append(c)
    matched=[]; total=Decimal(0)
    for g in groups.values():
        g.sort(key=lambda c:c['signed_at']); span=(date.fromisoformat(g[-1]['signed_at'])-date.fromisoformat(g[0]['signed_at'])).days
        amt=sum(D(c['amount']) for c in g); days=len({c['signed_at'] for c in g})
        if len(g)>=4 and days>=3 and span<=int(x['window_days']) and amt>=D(50000000): matched.extend(c['id'] for c in g); total=max(total,amt)
    return finish('SIGNAL' if matched else 'NO_SIGNAL',[],{'matched_contract_count':len(set(matched)),'matched_total_amount':str(total)},matched,[c['id'] for c in cs if c['id'] not in matched],x)

def eval_concentration(x):
    for p in ['contracts','minimum_total_spend']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    cs=contract_groups(x['contracts'])
    if any(c.get('supplier_id') is None or c.get('amount') is None for c in cs): return blocked('IDENTITY_AMBIGUOUS',x)
    total=sum(D(c['amount']) for c in cs)
    if total<D(x['minimum_total_spend']): return blocked('INSUFFICIENT_TOTAL_SPEND',x)
    sums={}; counts={}
    for c in cs: sums[c['supplier_id']]=sums.get(c['supplier_id'],Decimal(0))+D(c['amount']); counts[c['supplier_id']]=counts.get(c['supplier_id'],0)+1
    sid=max(sums,key=sums.get); share=sums[sid]/total
    matched=[c['id'] for c in cs if c['supplier_id']==sid]
    signal=share>=D('0.6') and counts[sid]>=3
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'top_supplier_id':sid,'top_supplier_share':q(share),'top_supplier_contract_count':counts[sid],'total_spend':str(total)},matched if signal else [],[c['id'] for c in cs if not signal or c['supplier_id']!=sid],x)

def eval_low_comp(x):
    for p in ['procurement.id','procurement.method','procurement.valid_bidder_count','procurement.estimated_amount','procurement.emergency']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    p=x['procurement']; competitive=p['method'] in ['OPEN_COMPETITION','LIMITED_COMPETITION']; signal=competitive and int(p['valid_bidder_count'])<=1 and D(p['estimated_amount'])>=D(50000000) and not p['emergency']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'valid_bidder_count':int(p['valid_bidder_count']),'estimated_amount':str(p['estimated_amount']),'competitive':competitive,'emergency':bool(p['emergency'])},[p['id']] if signal else [],[] if signal else [p['id']],x)

def eval_amendment(x):
    for p in ['contract.id','contract.original_amount','contract.final_amount','contract.amendment_count','contract.scope_change_explained']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    c=x['contract']; orig=D(c['original_amount'])
    if orig<=0: return blocked('ORIGINAL_AMOUNT_ZERO',x)
    ratio=D(c['final_amount'])/orig; signal=orig>=D(10000000) and int(c['amendment_count'])>=2 and ratio>=D('1.5') and not c['scope_change_explained']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'original_amount':str(c['original_amount']),'final_amount':str(c['final_amount']),'ratio':q(ratio),'amendment_count':int(c['amendment_count']),'scope_change_explained':bool(c['scope_change_explained'])},[c['id']] if signal else [],[] if signal else [c['id']],x)

def median(vals):
    vals=sorted(vals); n=len(vals); return vals[n//2] if n%2 else (vals[n//2-1]+vals[n//2])/2

def eval_year_end(x):
    for p in ['monthly_spend','monthly_contract_count']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    if len(x['monthly_spend'])!=12 or len(x['monthly_contract_count'])!=12: return blocked('INCOMPLETE_YEAR',x)
    spends=[D(v) for v in x['monthly_spend']]; counts=[int(v) for v in x['monthly_contract_count']]
    if sum(counts)<10: return blocked('INSUFFICIENT_CONTRACTS',x)
    annual=sum(spends); prior=median(spends[:11]); dec=spends[11]
    if annual<=0 or prior<=0: return blocked('INCOMPLETE_YEAR',x)
    share=dec/annual; ratio=dec/prior; signal=share>=D('0.25') and ratio>=D('3')
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'annual_spend':str(annual),'december_spend':str(dec),'december_share':q(share),'prior_month_median':q(prior),'december_to_prior_median':q(ratio),'annual_contract_count':sum(counts)},['month-12'] if signal else [],[] if signal else ['month-12'],x)

def eval_new_supplier(x):
    for p in ['supplier.id','supplier.age_days','supplier.agency_contract_count','supplier.agency_spend','supplier.total_public_spend','supplier.identity_verified']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    s=x['supplier']
    if not s['identity_verified']: return blocked('IDENTITY_AMBIGUOUS',x)
    total=D(s['total_public_spend'])
    if total<=0: return blocked('TOTAL_SPEND_ZERO',x)
    share=D(s['agency_spend'])/total; signal=int(s['age_days'])<=365 and int(s['agency_contract_count'])>=3 and D(s['agency_spend'])>=D(50000000) and share>=D('0.5')
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'supplier_age_days':int(s['age_days']),'agency_contract_count':int(s['agency_contract_count']),'agency_spend':str(s['agency_spend']),'total_public_spend':str(s['total_public_spend']),'agency_share':q(share)},[s['id']] if signal else [],[] if signal else [s['id']],x)

def eval_shared(x):
    for p in ['suppliers','contracts']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    suppliers=x['suppliers']; contracts=contract_groups(x['contracts'])
    if len(suppliers)<2 or len(contracts)<3: return blocked('INSUFFICIENT_CONTRACT_CONTEXT',x)
    if any(not s.get('strong_identifier_hashes') for s in suppliers): return blocked('IDENTITY_HASH_MISSING',x)
    best=None
    for i,a in enumerate(suppliers):
        for b in suppliers[i+1:]:
            shared=set(a['strong_identifier_hashes']) & set(b['strong_identifier_hashes'])
            relevant=[c for c in contracts if c.get('supplier_id') in {a['id'],b['id']}]
            agencies={c.get('agency_id') for c in relevant}; amt=sum(D(c.get('amount',0)) for c in relevant)
            if len(shared)>=2 and len(relevant)>=3 and len(agencies)==1 and amt>=D(50000000): best=(a,b,shared,relevant,amt); break
        if best: break
    if not best: return finish('NO_SIGNAL',[],{'shared_identifier_count':0,'combined_contract_count':0,'combined_amount':'0'},[],[c['id'] for c in contracts],x)
    a,b,shared,relevant,amt=best
    return finish('SIGNAL',[],{'supplier_ids':[a['id'],b['id']],'shared_identifier_count':len(shared),'combined_contract_count':len(relevant),'combined_amount':str(amt)},[c['id'] for c in relevant],[c['id'] for c in contracts if c not in relevant],x)

def eval_restrictive(x):
    for p in ['specification.id','specification.brand_mentions','specification.model_mentions','specification.equivalent_allowed','specification.valid_bidder_count','specification.justification_present']:
        if missing(x,p): return blocked('REQUIRED_FIELD_MISSING',x)
    s=x['specification']; mentions=int(s['brand_mentions'])+int(s['model_mentions']); signal=mentions>=1 and not s['equivalent_allowed'] and int(s['valid_bidder_count'])<=1 and not s['justification_present']
    return finish('SIGNAL' if signal else 'NO_SIGNAL',[],{'brand_mentions':int(s['brand_mentions']),'model_mentions':int(s['model_mentions']),'equivalent_allowed':bool(s['equivalent_allowed']),'valid_bidder_count':int(s['valid_bidder_count']),'justification_present':bool(s['justification_present'])},[s['id']] if signal else [],[] if signal else [s['id']],x)

EVALUATORS={'PRICE_OUTLIER':eval_price,'CONTRACT_SPLITTING_PATTERN':eval_split,'REPEATED_SINGLE_SOURCE':eval_repeated,'SUPPLIER_CONCENTRATION':eval_concentration,'LOW_BID_COMPETITION':eval_low_comp,'CONTRACT_AMENDMENT_ESCALATION':eval_amendment,'YEAR_END_SPENDING_SPIKE':eval_year_end,'NEW_SUPPLIER_DEPENDENCE':eval_new_supplier,'SHARED_SUPPLIER_IDENTITY':eval_shared,'RESTRICTIVE_SPECIFICATION':eval_restrictive}
def evaluate(rule_id,input_obj): return EVALUATORS[rule_id](input_obj)
def main():
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('rule_id',nargs='?')
    parser.add_argument('input_file',nargs='?',type=Path)
    parser.add_argument('--json-output',type=Path)
    args=parser.parse_args()
    if bool(args.rule_id) != bool(args.input_file):
        parser.error('rule_id and input_file must be supplied together')
    if args.rule_id:
        result=evaluate(args.rule_id,json.loads(args.input_file.read_text()))
        payload=json.dumps(result,ensure_ascii=False,sort_keys=True)+'\n'
        if args.json_output:
            args.json_output.parent.mkdir(parents=True,exist_ok=True);args.json_output.write_text(payload)
        print(payload,end='');return 0
    root=Path(__file__).resolve().parent/'evals'; total=0; errors=[]
    for path in sorted(root.glob('*.jsonl')):
        for line_no,line in enumerate(path.read_text().splitlines(),1):
            if not line.strip(): continue
            case=json.loads(line); actual=evaluate(case['rule_id'],case['input'])
            if actual!=case['expected']: errors.append({'file':path.name,'line':line_no,'id':case['id'],'expected':case['expected'],'actual':actual})
            total+=1
    result={'total':total,'errors':errors,'result':'PASS' if not errors else 'FAIL'}
    payload=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if args.json_output:
        args.json_output.parent.mkdir(parents=True,exist_ok=True);args.json_output.write_text(payload)
    print(payload,end='');return 0 if not errors else 1
if __name__=='__main__': raise SystemExit(main())
