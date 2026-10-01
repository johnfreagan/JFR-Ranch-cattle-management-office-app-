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
