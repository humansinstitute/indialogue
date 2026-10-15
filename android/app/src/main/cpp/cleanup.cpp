#include <jni.h>
#include <llama.h>
#include <string>
#include <vector>
#include <memory>
#include <stdexcept>
#include <mutex>
static std::once_flag initialized;
static std::string bytes(JNIEnv *e, jbyteArray a) { auto n=e->GetArrayLength(a); std::string s(n,'\0'); e->GetByteArrayRegion(a,0,n,reinterpret_cast<jbyte*>(s.data())); return s; }
static void error(JNIEnv *e,const char *s) { e->ThrowNew(e->FindClass("java/lang/IllegalStateException"),s); }
extern "C" JNIEXPORT jlong JNICALL Java_com_wingmanbefree_indialogue_LocalLlm_load(JNIEnv *e,jobject,jbyteArray path) {
    std::call_once(initialized, []{llama_backend_init();}); auto p=llama_model_default_params(); p.n_gpu_layers=0;
    auto *m=llama_model_load_from_file(bytes(e,path).c_str(),p); if(!m) { error(e,"Cleanup model could not be loaded. Check available memory and model integrity."); return 0; } return reinterpret_cast<jlong>(m);
}
extern "C" JNIEXPORT void JNICALL Java_com_wingmanbefree_indialogue_LocalLlm_free(JNIEnv*,jobject,jlong h) { if(h) llama_model_free(reinterpret_cast<llama_model*>(h)); }
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_wingmanbefree_indialogue_LocalLlm_generate(JNIEnv *e,jobject,jlong h,jbyteArray input,jobject cancel) {
    try {
        auto *m=reinterpret_cast<llama_model*>(h); if(!m) throw std::runtime_error("Model unavailable");
        auto p=llama_context_default_params(); p.n_ctx=2048; p.n_batch=512; p.n_threads=4; p.n_threads_batch=4;
        std::unique_ptr<llama_context,decltype(&llama_free)> ctx(llama_init_from_model(m,p),llama_free); if(!ctx) throw std::runtime_error("Insufficient memory for local cleanup");
        auto *v=llama_model_get_vocab(m); auto text=bytes(e,input);
        std::vector<llama_token> tokens(2048); int n=llama_tokenize(v,text.data(),text.size(),tokens.data(),tokens.size(),true,true);
        if(n<0||n>1100) throw std::runtime_error("Cleanup chunk exceeds model context; raw transcript retained"); tokens.resize(n);
        auto method=e->GetMethodID(e->GetObjectClass(cancel),"getAsBoolean","()Z");
        auto cancelled=[&](){return e->CallBooleanMethod(cancel,method)==JNI_TRUE;};
        for(int start=0;start<n;start+=512) { if(cancelled()) throw std::runtime_error("Cleanup cancelled"); auto batch=llama_batch_get_one(tokens.data()+start,std::min(512,n-start)); if(llama_decode(ctx.get(),batch)!=0) throw std::runtime_error("Local cleanup decode failed"); }
        std::unique_ptr<llama_sampler,decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(),llama_sampler_free);
        std::string out; bool ended=false;
        for(int i=0;i<800;i++) { if(cancelled()) throw std::runtime_error("Cleanup cancelled"); auto t=llama_sampler_sample(sampler.get(),ctx.get(),-1); if(llama_vocab_is_eog(v,t)){ended=true;break;} char buf[256]; int size=llama_token_to_piece(v,t,buf,sizeof(buf),0,true); if(size<0) throw std::runtime_error("Invalid output token"); out.append(buf,size); auto batch=llama_batch_get_one(&t,1); if(llama_decode(ctx.get(),batch)!=0) throw std::runtime_error("Local cleanup context exhausted"); }
        if(!ended) throw std::runtime_error("Cleanup output limit reached; draft refused to avoid truncation");
        auto result=e->NewByteArray(out.size()); e->SetByteArrayRegion(result,0,out.size(),reinterpret_cast<const jbyte*>(out.data())); return result;
    } catch(const std::exception &x) {error(e,x.what());return nullptr;}
}
