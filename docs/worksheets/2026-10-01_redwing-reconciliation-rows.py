from decimal import Decimal as D
H=lambda s:s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def M(x,dash=True):
    if x==0 and dash: return '&mdash;'
    return ('&minus;$' if x<0 else '$')+f"{abs(x):,.2f}"
# med, redwing line, rw 9/30, done/acct adj, jayci adj, count, shelf, tag
L=[
 ("Excede","Excede 100 ML + Excede 250 ML",D("7730.11"),D("-2077.36"),D("1013.23"),D("6665.98"),
  "barn 24 x 100 mL + 1 x 250 mL; trucks 1 x 100 + 1 x 250 + two at 1/4 of a 250","mix"),
 ("Resflor","Resflor 250 ML + Resflor 500 ML",D("4153.81"),D("0"),D("726.92"),D("4880.73"),
  "barn 10 x 500 mL; trucks 2 at 1/2 full + 3/4 of a 500 (confirmed)","crew"),
 ("Enroflox(Baytril)","Enroflox 500 ML",D("3854.87"),D("0"),D("458.91"),D("4313.78"),
  "barn 21 x 500 mL; trucks 3/4 + 1/2 + 3/4 + 1/2 (confirmed)","crew"),
 ("Draxxin KP","Draxxin KP",D("441.00"),D("0"),D("220.50"),D("661.50"),
  "barn 1 x 250 mL; trucks 1/2 bottle","crew"),
 ("Macrosyn(Draxxin)","Macrosyn 250 ML",D("373.15"),D("-373.15"),D("0"),D("0"),
  "none - the truck bottle was Draxxin KP","acct"),
 ("Multi Min","Multi Min",D("919.03"),D("0"),D("306.34"),D("1225.37"),"barn 4 x 500 mL","jayci"),
 ("One Grass","One Grass",D("1804.00"),D("0"),D("-1804.00"),D("0"),"none, expired","jayci"),
 ("Synovex S","Synovex S",D("165.00"),D("0"),D("-165.00"),D("0"),"none, expired","jayci"),
 ("Synovex C 100 Ds Prestige","Synovex C",D("121.00"),D("0"),D("-121.00"),D("0"),"none, expired","jayci"),
 ("Cydectin","Cydectin",D("1511.96"),D("0"),D("0"),D("1511.96"),"barn 2 x 5 L",""),
 ("Dectomax","Dectomax",D("609.50"),D("0"),D("0"),D("609.50"),"barn 5 x 500 mL",""),
 ("Estrumate","Estrumate",D("105.00"),D("0"),D("0"),D("105.00"),"barn 1 x 100 mL",""),
 ("Biomycin","Biomycin",D("69.44"),D("0"),D("0"),D("69.44"),"barn 1 x 500 mL",""),
 ("Thiamine","Thiamine",D("38.38"),D("0"),D("0"),D("38.38"),"barn 2 x 100 mL",""),
 ("Protivity","Mycroplasm 50 Dose + Mycroplasma 10 Dose",D("0"),D("0"),D("0"),D("0"),
  "8 x 10-dose boxes, already expensed - to processing at no cost","note"),
 ("Brute","Brute",D("0"),D("0"),D("0"),D("0"),"none",""),
 ("Draxxin","Draxxin 250 ML",D("0"),D("0"),D("0"),D("0"),"none",""),
 ("Ultrachoice 8","Ultrachoice",D("0"),D("0"),D("0"),D("0"),"none",""),
 ("Vitamin K","Vitamin K",D("0"),D("0"),D("0"),D("0"),"none",""),
 ("Synovex Primer","not carried",D("0"),D("0"),D("0"),D("0"),"none",""),
 ("Ivomec Long Range Wormer","not carried",D("0"),D("0"),D("0"),D("0"),
  "2 bottles here, going back to the vendor","note"),
 ("(not in the catalog)","Fly Spray, Valbazen, Vira Shield 50 Dose",D("0"),D("0"),D("0"),D("0"),"none",""),
]
rw=sum(r[2] for r in L); dn=sum(r[3] for r in L); jy=sum(r[4] for r in L); cn=sum(r[5] or D(0) for r in L)
assert rw==D("21896.25"), rw
assert dn==D("-2450.51"), dn
assert jy==D("635.90"), jy
assert cn==D("20081.64"), cn
assert rw+dn+jy==cn, (rw,dn,jy,cn)
CREW=D("726.92")+D("458.91")+D("1013.23")+D("220.50"); assert CREW==D("2419.56")
EXPIRED=D("1804.00")+D("165.00")+D("121.00"); assert EXPIRED-D("306.34")==D("1783.66")
assert CREW-(EXPIRED-D("306.34"))==jy, (CREW, EXPIRED, jy)
print(f"Redwing {rw}  done/acct {dn}  Jayci {jy}  count {cn}  TIES")
print(f"crew stock {CREW}   expired net {EXPIRED-D('306.34')}   Jayci net {jy}")

CL={"jayci":"do","mix":"part do","acct":"accts","crew":"crew","open":"open","note":"note","":""}
def tr(r):
    med,line,a,b,c,cnt,shelf,tag=r
    cls={"jayci":"act","mix":"act","acct":"act","crew":"act","open":"open","note":"open","":"zero"}[tag]
    t=CL[tag]
    return f"""<tr class="{cls}">
 <td class="med">{H(med)}{f'<span class="tag">{t}</span>' if t else ''}</td>
 <td class="rw">{H(line)}</td><td class="n">{M(a,False)}</td>
 <td class="n">{M(b)}</td><td class="n j">{M(c)}</td>
 <td class="n">{M(a+b+c,False)}</td>
 <td class="n">{M(cnt,False) if cnt is not None else '<i>not counted</i>'}</td>
 <td class="d">{H(shelf)}</td></tr>"""
open("rows3.html","w").write("\n".join(tr(r) for r in L))

# =====================================================================
# QUANTITIES. John wants amounts alongside dollars for a while, to check
# the office app against Redwing before trusting dollars alone.
#
# The test this table applies: EVERY entry Jayci has to make should be a
# quantity difference times that line's own rate. Two of the day's
# adjustments are not, and those two are the errors - value moving with
# no product behind it. That is the whole argument for running both
# columns, so the assertions below are written to prove it rather than
# to decorate it.
#
# med, Redwing containers as printed, Redwing amount, count amount,
# unit, rate, what the difference is
# =====================================================================
Q=[
 ("Excede","24 x 100 mL + 1 x 250 mL",D("2650"),D("3125"),"mL",D("2.133113"),
  "475 mL in the trucks"),
 ("Resflor","10 x 500 mL",D("5000"),D("5875"),"mL",D("0.830762"),
  "875 mL in the trucks"),
 ("Enroflox(Baytril)","21 x 500 mL",D("10500"),D("11750"),"mL",D("0.367130"),
  "1,250 mL in the trucks"),
 ("Draxxin KP","1 x 250 mL",D("250"),D("375"),"mL",D("1.764000"),
  "125 mL in a truck"),
 ("Multi Min","3 x 500 mL",D("1500"),D("2000"),"mL",D("0.612687"),
  "a fourth bottle Redwing does not have"),
 ("One Grass","400 units",D("400"),D("0"),"units",D("4.51"),
  "expired, disposed of"),
 ("Synovex S","150 doses",D("150"),D("0"),"doses",D("1.10"),
  "expired"),
 ("Synovex C 100 Ds Prestige","110 doses",D("110"),D("0"),"doses",D("1.10"),
  "expired"),
 ("Macrosyn(Draxxin)","none",D("0"),D("0"),"mL",None,
  "VALUE WITH NO QUANTITY - see below"),
 ("Cydectin","2 x 5 L",D("10000"),D("10000"),"mL",D("0.151196"),""),
 ("Dectomax","5 x 500 mL",D("2500"),D("2500"),"mL",D("0.243800"),""),
 ("Estrumate","1 x 100 mL",D("100"),D("100"),"mL",D("1.050000"),""),
 ("Biomycin","1 x 500 mL",D("500"),D("500"),"mL",D("0.138880"),""),
 ("Thiamine","2 x 100 mL",D("200"),D("200"),"mL",D("0.191900"),""),
 ("Protivity","none",D("0"),D("0"),"doses",None,
  "8 boxes, 80 doses on the shelf - already expensed, no cost either side"),
 ("Ivomec Long Range Wormer","none",D("0"),D("0"),"mL",None,
  "2 bottles here, going back to the vendor"),
]

# Redwing's own control total on the report is 731.00 CONTAINERS, and it
# has to come back out of this table or the quantities are read wrong.
CONTAINERS={"Excede":25,"Resflor":10,"Enroflox(Baytril)":21,"Draxxin KP":1,
            "Multi Min":3,"One Grass":400,"Synovex S":150,
            "Synovex C 100 Ds Prestige":110,"Cydectin":2,"Dectomax":5,
            "Estrumate":1,"Biomycin":1,"Thiamine":2,"Macrosyn(Draxxin)":0,
            "Protivity":0,"Ivomec Long Range Wormer":0}
assert sum(CONTAINERS.values())==731, sum(CONTAINERS.values())

# THE ASSERTION THAT MATTERS: for every line, the entry Jayci makes is
# the quantity difference times that line's own rate. Where it is not,
# the line is named as an exception rather than quietly skipped.
JY={r[0]: r[4] for r in L}
NO_QUANTITY_BEHIND_IT = {"Macrosyn(Draxxin)"}
for med, _, rw_q, cn_q, _, rate, _ in Q:
    if rate is None:
        assert med in NO_QUANTITY_BEHIND_IT or JY[med]==0, (med, JY[med])
        continue
    implied = ((cn_q - rw_q) * rate).quantize(D("0.01"))
    assert implied == JY[med], (med, implied, JY[med])
    # and the count value has to be the count quantity at the same rate
    assert (cn_q*rate).quantize(D("0.01")) == next(r[5] for r in L if r[0]==med), med

# Macrosyn is the exception, and it is the exception on purpose: $373.15
# of value against zero quantity on both sides. Excede is the other one -
# $2,077.36 came out of its value on 10/1 and its quantity never moved.
assert JY["Macrosyn(Draxxin)"]==0
assert next(r[3] for r in L if r[0]=="Macrosyn(Draxxin)")==D("-373.15")
assert next(r[3] for r in L if r[0]=="Excede")==D("-2077.36")
rwq=next(r for r in Q if r[0]=="Excede"); assert rwq[2]==rwq[3]-D("475")

CREWQ={"Excede":D("475"),"Resflor":D("875"),"Enroflox(Baytril)":D("1250"),
       "Draxxin KP":D("125")}
assert sum((CREWQ[m]*next(r[5] for r in Q if r[0]==m)).quantize(D("0.01"))
           for m in CREWQ)==CREW
print(f"quantities tie: 731 containers, every Jayci entry = qty diff x rate, "
      f"crew {sum(CREWQ.values())} units = {CREW}")

def qtr(r):
    med,cont,rw,cn,unit,rate,note=r
    d=cn-rw
    cls="act" if d!=0 else ("open" if note else "zero")
    dtxt = '&mdash;' if d==0 else ('+' if d>0 else '&minus;')+f"{abs(d):,.0f}"
    dollars = '&mdash;' if (rate is None or d==0) else \
        (('+$' if d>0 else '&minus;$')+f"{abs((d*rate).quantize(D('0.01'))):,.2f}")
    return f"""<tr class="{cls}">
 <td class="med">{H(med)}</td><td class="rw">{H(cont)}</td>
 <td class="n">{rw:,.0f}</td><td class="n">{cn:,.0f}</td>
 <td class="n"><b>{dtxt}</b></td><td class="u">{H(unit)}</td>
 <td class="n">{dollars}</td><td class="d">{H(note)}</td></tr>"""
open("qrows.html","w").write("\n".join(qtr(r) for r in Q))
