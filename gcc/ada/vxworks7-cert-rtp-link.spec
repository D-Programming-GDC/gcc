*self_spec:
+ %{!nostdlib:-nodefaultlibs -nostartfiles}

*link:
+ %{!nostdlib:%{mrtp:%{!shared: \
     -l:certRtp.o \
     -L%:getenv(VSB_DIR /usr/lib/common/objcert) \
     -T%:getenv(VSB_DIR /usr/ldscripts/rtp.ld) \
   }}}
