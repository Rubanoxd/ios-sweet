// sweet-stack PID: user backtraces of every thread (frame-pointer walk), symbolized through the shared cache.
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
static int rd(task_t t, uint64_t a, uint64_t *v){vm_size_t n=8;return vm_read_overwrite(t,a,8,(vm_address_t)v,&n)==KERN_SUCCESS;}
static void sym(uint64_t pc){Dl_info i;if(dladdr((void*)pc,&i)&&i.dli_sname)printf("    %llx %s + %llu (%s)\n",pc,i.dli_sname,pc-(uint64_t)i.dli_saddr,i.dli_fname?:"");else printf("    %llx\n",pc);}
int main(int argc,char**argv){
  task_t t;if(task_for_pid(mach_task_self(),atoi(argv[1]),&t)){printf("task_for_pid failed\n");return 1;}
  thread_act_array_t th;mach_msg_type_number_t n;task_threads(t,&th,&n);
  for(unsigned i=0;i<n;i++){
    arm_thread_state64_t s;mach_msg_type_number_t c=ARM_THREAD_STATE64_COUNT;
    if(thread_get_state(th[i],ARM_THREAD_STATE64,(thread_state_t)&s,&c))continue;
    uint64_t pc=__darwin_arm_thread_state64_get_pc(s)&0xfffffffffULL, lr=__darwin_arm_thread_state64_get_lr(s)&0xfffffffffULL, fp=__darwin_arm_thread_state64_get_fp(s);
    printf("thread %u:\n",i);sym(pc);sym(lr);
    for(int d=0;d<40&&fp;d++){uint64_t nfp,ret;if(!rd(t,fp,&nfp)||!rd(t,fp+8,&ret))break;ret&=0xfffffffffULL;if(!ret)break;sym(ret);fp=nfp;}
  }
  return 0;}
