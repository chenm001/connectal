import syntax
import AST
import util

applicationmk_template='''
APP_STL                 := stlport_static
'''

androidmk_template='''
LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)
LOCAL_SRC_FILES := %(ClassName)s.cpp portal.cpp test%(classname)s.cpp
LOCAL_MODULE = test%(classname)s
LOCAL_MODULE_TAGS := optional
LOCAL_LDLIBS := -llog

include $(BUILD_EXECUTABLE)
'''

classPrefixTemplate='''
class %(namespace)s%(className)s : public PortalInstance {
public:
    static %(className)s *create%(className)s(const char *instanceName, %(className)sIndications *indications=0);
'''
classSuffixTemplate='''
protected:
    %(className)s(const char *instanceName, %(className)sIndications *indications=0);
    ~%(className)s();
};
'''

indicationClassPrefixTemplate='''
class %(namespace)s%(className)s : public PortalIndications {
public:
    %(className)s();
    virtual ~%(className)s();
'''
indicationClassSuffixTemplate='''
protected:
    virtual void handleMessage(PortalMessage *msg);
    friend class PortalInstance;
};
'''

creatorTemplate = '''
%(namespace)s%(className)s *%(namespace)s%(className)s::create%(className)s(const char *instanceName, %(className)sIndications *indications)
{
    %(namespace)s%(className)s *instance = new %(namespace)s%(className)s(instanceName, indications);
    return instance;
}
'''
constructorTemplate='''
%(namespace)s%(className)s::%(className)s(const char *instanceName, %(className)sIndications *indications)
 : PortalInstance(instanceName, indications)%(initializers)s
{
}
%(namespace)s%(className)s::~%(className)s()
{
    close();
}
'''

indicationConstructorTemplate='''
%(namespace)s%(className)s::%(className)s()
{
}
%(namespace)s%(className)s::~%(className)s()
{
}
'''

handleMessageTemplate='''
void %(namespace)s%(className)s::handleMessage(PortalMessage *msg)
{
    switch (msg->channel) {
%(responseCases)s
    default: break;
    }
}
'''

requestTemplate='''
struct %(className)s%(methodName)sMSG : public PortalMessage
{
    struct Request {
    //fix Adapter.bsv to unreverse these
%(paramStructDeclarations)s
    } request;
};

void %(namespace)s%(className)s::%(methodName)s ( %(paramDeclarations)s )
{
    %(className)s%(methodName)sMSG msg;
    msg.size = sizeof(msg.request);
    msg.channel = %(methodChannelOffset)s;
%(paramSetters)s
    sendMessage(&msg);
};
'''

responseTemplate='''
struct %(className)s%(methodName)sMSG : public PortalMessage
{
//fix Adapter.bsv to unreverse these
%(paramStructDeclarations)s
};
'''

def indent(f, indentation):
    for i in xrange(indentation):
        f.write(' ')

def capitalize(s):
    return '%s%s' % (s[0].upper(), s[1:])

class NoCMixin:
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        pass
    def emitCImplementation(self, f):
        pass

class MethodMixin:
    def collectTypes(self):
        result = [self.return_type]
        result.append(AST.Type('Tuple', self.params))
        return result
    def resultTypeName(self):
        if (self.return_type):
            return self.return_type.cName()
        else:
            return int
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        indent(f, indentation)
        resultTypeName = self.resultTypeName()
        if self.isIndication:
            f.write('virtual ')
        f.write('void %s ( ' % cName(self.name))
        #print parentClassName, self.name
        f.write(', '.join([cName(p.type) for p in self.params]))
        f.write(' )')
        if not self.isIndication:
            f.write(';\n')
        else:
            f.write('{ }\n')
    def emitCImplementation(self, f, className, namespace):
        params = self.params
        paramDeclarations = [ '%s %s' % (p.type.cName(), p.name) for p in params]
        paramStructDeclarations = [ '        %s %s%s;\n' % (p.type.cName(), p.name, p.type.bitSpec()) for p in params]
        if not params:
            paramStructDeclarations = ['        int padding;\n']
        ## fix Adapter.bsv to eliminate the need for this reversal
        paramStructDeclarations.reverse()
        paramSetters = [ '    msg.request.%s = %s;\n' % (p.name, p.name) for p in params]
        resultTypeName = self.resultTypeName()
        substs = {
            'namespace': namespace,
            'className': className,
            'methodName': cName(self.name),
            'MethodName': capitalize(cName(self.name)),
            'paramDeclarations': ', '.join(paramDeclarations),
            'paramStructDeclarations': ''.join(paramStructDeclarations),
            'paramSetters': ''.join(paramSetters),
            'paramNames': ', '.join(['msg->%s' % p.name for p in params]),
            'resultType': resultTypeName,
            'methodChannelOffset': self.channelNumber,
            }
        if not self.isIndication:
            f.write(requestTemplate % substs)
        else:
            f.write(responseTemplate % substs)

class StructMemberMixin:
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        indent(f, indentation)
        f.write('%s %s' % (self.type.cName(), self.tag))
        #print 'emitCDeclaration: ', self.type, self.type.isBitField, self.type.cName(), self.tag
        if self.type.isBitField():
            f.write(' : %d' % self.type.bitWidth())
        f.write(';\n')

class StructMixin:
    def collectTypes(self):
        result = [self]
        result.append(self.elements)
        return result
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        indent(f, indentation)
        if (indentation == 0):
            f.write('typedef ')
        f.write('struct %s {\n' % self.name.cName())
        for e in self.elements:
            e.emitCDeclaration(f, indentation+4)
        indent(f, indentation)
        f.write('}')
        if (indentation == 0):
            f.write(' %s;' % self.name.cName())
        f.write('\n')
    def emitCImplementation(self, f, className='', namespace=''):
        pass

class EnumElementMixin:
    def cName(self):
        return self.name

class EnumMixin:
    def collectTypes(self):
        result = [self]
        return result
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        indent(f, indentation)
        if (indentation == 0):
            f.write('typedef ')
        f.write('enum %s { ' % self.name.cName())
        indent(f, indentation)
        f.write(', '.join([e.cName() for e in self.elements]))
        indent(f, indentation)
        f.write(' }')
        if (indentation == 0):
            f.write(' %s;' % self.name.cName())
        f.write('\n')
    def emitCImplementation(self, f, className='', namespace=''):
        pass

class InterfaceMixin:
    def collectTypes(self):
        result = [d.collectTypes() for d in self.decls]
        return result
    def getSubinterface(self, name):
        subinterfaceName = name
        if not syntax.globalvars.has_key(subinterfaceName):
            return None
        subinterface = syntax.globalvars[subinterfaceName]
        #print 'subinterface', subinterface, subinterface
        return subinterface
    def assignRequestResponseChannels(self, channelNumber=0):
        for d in self.decls:
            if d.__class__ == AST.Interface:
                i = self.getSubinterface(d.name)
                if not i:
                    continue
                d.baseChannelNumber = channelNumber
                channelNumber = channelNumber + i.channelCount 
            elif d.__class__ == AST.Method:
                d.channelNumber = channelNumber
                channelNumber = channelNumber + 1
        self.channelCount = channelNumber
    def emitCDeclaration(self, f, indentation=0, parentClassName='', namespace=''):
        self.toplevel = (indentation == 0)
        name = cName(self.name)
        indent(f, indentation)
        if self.isIndication:
            prefixTemplate = indicationClassPrefixTemplate
            suffixTemplate= indicationClassSuffixTemplate
        else:
            prefixTemplate = classPrefixTemplate
            suffixTemplate = classSuffixTemplate
        f.write(prefixTemplate % {'className': name,
                                  'namespace': namespace})
        for d in self.decls:
            if d.type == 'Interface':
                continue
            d.isIndication = self.isIndication
            d.emitCDeclaration(f, indentation + 4, name, namespace)
        f.write(suffixTemplate % {'className': name,
                                  'namespace': namespace})
        return
    def emitCImplementation(self, f, parentClassName='', namespace=''):
        if parentClassName:
            namespace = '%s%s::' % (namespace, parentClassName)
        className = cName(self.name)
        self.emitConstructorImplementation(f, className, namespace)
        for d in self.decls:
            if d.type == 'Interface':
                continue
            d.emitCImplementation(f, className, namespace)

        substitutions = {'namespace': namespace,
                         'className': className,
                         'responseCases': ''.join([ '    case %(channelNumber)s: %(name)s(%(params)s); break;\n'
                                                   % { 'channelNumber': d.channelNumber,
                                                       'name': d.name,
                                                       'className': className,
                                                       'params': ', '.join(['((%s%sMSG *)msg)->%s' % (className, d.name, p.name) for p in d.params])}
                                                   for d in self.decls 
                                                   if d.type == 'Method' and d.return_type.name == 'Action'
                                                    ])
                         }
        if self.isIndication:
            f.write(handleMessageTemplate % substitutions)

    def emitConstructorImplementation(self, f, className, namespace):
        substitutions = {'namespace': namespace,
                         'className': className,
                         'initializers': ''}
        subinterfaces = []
        for d in self.decls:
            if d.__class__ == AST.Interface:
                subinterfaces.append(d.subinterfacename)
        ## not generating code for subinterfaces for now
        ## if subinterfaces:
        ##     substitutions['initializers'] = (', %s'
        ##                                      % ', '.join([ '%s(p)' % i for i in subinterfaces]))
        if self.toplevel:
            if not self.isIndication:
                f.write(creatorTemplate % substitutions)
        if self.isIndication:
            f.write(indicationConstructorTemplate % substitutions)
        else:
            f.write(constructorTemplate % substitutions)
        return
    def writeAndroidMk(self, androidmkname, applicationmkname, silent=False):
        f = util.createDirAndOpen(androidmkname, 'w')
        className = cName(self.name)
        substs = {
            'ClassName': className,
            'classname': className.lower()
        }
        f.write(androidmk_template % substs)
        f.close()
        f = util.createDirAndOpen(applicationmkname, 'w')
        className = cName(self.name)
        f.write(applicationmk_template % substs)
        f.close()

class ParamMixin:
    def cName(self):
        return self.name

class TypeMixin:
    def cName(self):
        cid = self.name
        cid = cid.replace(' ', '')
        if cid == 'Bit':
            if self.params[0].numeric() <= 32:
                return 'unsigned long'
            elif self.params[0].numeric() <= 64:
                return 'unsigned long long'
            else:
                return 'std::bitset<%d>' % (self.params[0].numeric())
        elif cid == 'Action':
            return 'int'
        elif cid == 'ActionValue':
            return self.params[0].cName()
        if self.params:
            name = '%sL_%s_P' % (cid, '_'.join([cName(t) for t in self.params if t]))
        else:
            name = cid
        return name
    def isBitField(self):
        return self.name == 'Bit'
    def bitWidth(self):
        if self.name == 'Bit':
            return int(self.params[0].name)
        else:
            return 0
    def bitSpec(self):
        if self.isBitField():
            bw = self.bitWidth()
            if bw != 32:
                return ':%d' % bw
        return ''

def cName(x):
    if type(x) == str:
        x = x.replace(' ', '')
        x = x.replace('.', '$')
        return x
    else:
        return x.cName()
