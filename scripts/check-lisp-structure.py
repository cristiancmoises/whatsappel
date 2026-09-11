"""Static Lisp delimiter/binding checks, NOT Emacs/Guile evaluation."""
import sys
# SPDX-License-Identifier: AGPL-3.0-only
from pathlib import Path
class Atom(str): pass
class String(str): pass
class Form(list):
    def __init__(self,items=(),line=0):super().__init__(items);self.line=line

def read(text,scheme=False):
    i=0; line=1; tokens=[]
    if text.startswith('#!/'):
        stop=text.find('!#'); text='\n'*text[:stop+2].count('\n')+text[stop+2:]
    while i<len(text):
        c=text[i]
        if c.isspace():line+=c=='\n';i+=1;continue
        if c==';':
            j=text.find('\n',i);i=len(text) if j<0 else j;continue
        if c=='"':
            start=i;ln=line;i+=1
            while i<len(text):
                if text[i]=='\\':i+=2;continue
                if text[i]=='"':i+=1;break
                line+=text[i]=='\n';i+=1
            else:raise ValueError(f'unclosed string at {ln}')
            tokens.append((String(text[start:i]),ln));continue
        if (not scheme and c=='?' and (i==0 or text[i-1] in ' (\n\t\'')) or (scheme and text[i:i+2]=='#\\'):
            start=i;i+=2 if scheme else 1
            if not scheme and i<len(text) and text[i]=='\\': i+=1
            i+=1
            # Named Scheme characters; Elisp escape modifiers are left atoms.
            while i<len(text) and text[i] not in '()[] \n\t':i+=1
            tokens.append((Atom(text[start:i]),line));continue
        if c in '()[]':tokens.append((c,line));i+=1;continue
        if text[i:i+2] in ["#'",',@']:
            tokens.append((Atom(text[i:i+2]),line));i+=2;continue
        if c in "'`,":tokens.append((Atom(c),line));i+=1;continue
        start=i
        while i<len(text) and text[i] not in '()[] \t\r\n;"':i+=1
        if start==i:raise ValueError((i,line))
        tokens.append((Atom(text[start:i]),line))
    k=0
    def item():
        nonlocal k
        tok,ln=tokens[k];k+=1
        if type(tok) is str and tok in ('(', '['):
            end=')' if tok=='(' else ']';f=Form(line=ln)
            while k<len(tokens) and tokens[k][0]!=end:f.append(item())
            if k==len(tokens):raise ValueError(f'unclosed {tok} at {ln}')
            k+=1;return f
        if type(tok) is str and tok in (')',']'):raise ValueError(f'unexpected {tok} at {ln}')
        if type(tok) is Atom and tok in ("'",'`',',',',@',"#'"):
            return Form([Atom({'\'':'quote','#\'':'function','`':'quasiquote',',':'unquote',',@':'unquote-splicing'}[tok]),item()],ln)
        return tok
    out=[]
    while k<len(tokens):out.append(item())
    return out

def shapes(forms):
    issues=[]
    def visit(f):
        if not isinstance(f,Form) or not f:return
        head=f[0]
        if head in ['quote','quasiquote']:return
        if head in ['let','let*','cl-labels','cl-flet','cl-letf'] and len(f)>1:
            index=2 if head in ['let','let*'] and isinstance(f[1],Atom) else 1
            bindings=f[index]
            if not isinstance(bindings,Form):issues.append((f.line,'non-list bindings',head))
            else:
                for x in bindings:
                    if head=='cl-letf':
                        good=isinstance(x,Form) and len(x)==2
                    elif head in ['cl-labels','cl-flet']:
                        good=isinstance(x,Form) and len(x)>=3 and isinstance(x[0],Atom) and isinstance(x[1],Form)
                    else:good=isinstance(x,Atom) or (isinstance(x,Form) and 1<=len(x)<=2 and isinstance(x[0],Atom))
                    if not good:issues.append((getattr(x,'line',f.line),'invalid binding',repr(x)[:100]))
            if len(f)<=index+1: issues.append((f.line,'binding form has no body',head))
        for x in f:visit(x)
    for f in forms:visit(f)
    return issues
if __name__=='__main__':
    failed=False
    for path in sys.argv[1:]:
        try:
            fs=read(Path(path).read_text(),path.endswith('.scm'));issues=shapes(fs)
            print(path, 'forms',len(fs),'shape issues',issues)
            # Top-level definitions containing another defun/define indicate a
            # misplaced closing delimiter. Internal helpers inside definitions
            # are legal Scheme, so only report top-level names for inspection.
            print('last definitions', [f[1] for f in fs if isinstance(f,Form) and f and f[0] in ['defun','define','define*']][-10:])
            failed |= bool(issues)
        except ValueError as e:print(path,str(e));failed=True
    sys.exit(int(failed))
