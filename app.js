import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY, BUSINESS_WHATSAPP, STORAGE_BUCKET } from './config.js';
const configured = !SUPABASE_URL.includes('YOUR-PROJECT') && !SUPABASE_ANON_KEY.includes('YOUR-');
const db = configured ? createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;
const $ = s => document.querySelector(s);
let settings = {regular_price:200000,daily_capacity:3,whatsapp_number:BUSINESS_WHATSAPP}, calendar, adminCalendar;
const fmt = n => new Intl.NumberFormat('id-ID').format(Number(n||0));
const esc = s => String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const msg = (id,text) => { const e=$(id); if(e)e.textContent=text; };
const wa = text => { const n=String(settings.whatsapp_number||BUSINESS_WHATSAPP).replace(/\D/g,''); return n && !n.includes('xxxxxxxx') ? `https://wa.me/${n}?text=${encodeURIComponent(text)}` : '#'; };
function modal(id,on=true){$(id).classList.toggle('open',on)}
function updateContactLinks(){ $('#weddingLink').href=wa('Halo BYSL_MUA, saya ingin konsultasi layanan Wedding Makeup.'); $('#footerWa').href=wa('Halo BYSL_MUA, saya ingin bertanya tentang layanan makeup.'); }
async function loadSettings(){
 if(!db){updateContactLinks();return}
 const {data,error}=await db.from('site_settings').select('key,value'); if(error){console.error(error);return}
 for(const r of data||[]) settings[r.key]=r.value;
 $('#regularPrice').textContent=`Rp ${fmt(settings.regular_price)}`;
 $('#serviceType option:first-child').textContent=`Regular Makeup — Rp ${fmt(settings.regular_price)}`;
 $('#aboutCopy').textContent=settings.about_text||$('#aboutCopy').textContent;
 $('#contentForm [name=brand_name]').value=settings.brand_name||'MAKEUP ARTIST BY Siti Lestari';
 $('#contentForm [name=regular_price]').value=settings.regular_price||200000;
 $('#contentForm [name=daily_capacity]').value=settings.daily_capacity||3;
 $('#contentForm [name=whatsapp_number]').value=settings.whatsapp_number||'';
 $('#contentForm [name=instagram]').value=settings.instagram||'';
 $('#contentForm [name=about_text]').value=settings.about_text||'';
 updateContactLinks();
}
async function loadPortfolio(){
 if(!db)return; const {data,error}=await db.from('portfolio').select('id,image_url,caption').order('created_at',{ascending:false}); if(error){console.error(error);return}
 $('#portfolioGrid').innerHTML=(data||[]).length?(data||[]).map(p=>`<article class="portfolio-item"><img src="${esc(p.image_url)}" alt="${esc(p.caption||'Portfolio BYSL_MUA')}"><p>${esc(p.caption||'BYSL_MUA')}</p></article>`).join(''):'<div class="empty">Portfolio photos will appear here.</div>';
}
async function calendarEvents(start,end){
 if(!db)return [];
 const {data,error}=await db.rpc('get_public_calendar',{start_date:start,end_date:end});
 if(error){console.error('Calendar RPC:',error);return []}
 return (data||[]).map(r=>{const used=Number(r.booked_count||0),cap=Number(r.daily_capacity||settings.daily_capacity||3),pending=Number(r.pending_count||0),status=r.blocked?'blocked':used>=cap?'booked':pending?'pending':'available';
 const title=status==='blocked'?'Unavailable':status==='booked'?'Fully booked':status==='pending'?`Pending · ${pending}`:`Available · ${Math.max(0,cap-used)} slot`;
 return {id:r.event_date,title,start:r.event_date,allDay:true,classNames:[`event-${status}`],extendedProps:{status,used,cap,pending}};
 });
}
async function makeCalendar(el,isAdmin=false){
 const c=new FullCalendar.Calendar(el,{initialView:'dayGridMonth',height:'auto',locale:'id',headerToolbar:{left:'prev,next today',center:'title',right:''},buttonText:{today:'Hari ini'},events:async(info,success)=>{const start=info.startStr.slice(0,10),end=info.endStr.slice(0,10);if(isAdmin){const {data,error}=await db.from('bookings').select('id,event_date,status,customer_name,service_type').gte('event_date',start).lte('event_date',end).in('status',['pending','booked','blocked']);if(error){console.error(error);success([]);return}success((data||[]).map(b=>({id:b.id,title:b.status==='pending'?'Pending':b.status==='blocked'?'Unavailable':`Booked · ${b.customer_name}`,start:b.event_date,allDay:true,classNames:[`event-${b.status}`],extendedProps:b})));}else success(await calendarEvents(start,end));},dateClick:info=>{if(!isAdmin)openBooking(info.dateStr)},eventClick:info=>{if(isAdmin)adminEvent(info.event);else if(info.event.extendedProps.status==='available'||info.event.extendedProps.status==='pending')openBooking(info.event.startStr)}});c.render();return c;
}
function openBooking(date){$('#eventDate').value=date;$('#chosenDate').textContent=new Date(date+'T00:00:00').toLocaleDateString('id-ID',{weekday:'long',day:'numeric',month:'long',year:'numeric'});msg('#bookingMessage','');modal('#bookingModal')}
$('#bookingForm').addEventListener('submit',async e=>{
 e.preventDefault();if(!db){msg('#bookingMessage','Website belum terhubung ke Supabase. Lengkapi config.js terlebih dahulu.');return}
 const f=new FormData(e.currentTarget),v=Object.fromEntries(f.entries()),button=$('#sendBooking');button.disabled=true;button.textContent='Mengirim...';
 try{
  const {data,error}=await db.rpc('create_booking_request',{p_customer_name:v.customer_name,p_whatsapp:v.whatsapp,p_event_date:v.event_date,p_event_time:v.event_time,p_service_type:v.service_type,p_event_type:v.event_type,p_location:v.location,p_notes:v.notes||''});
  if(error)throw error;
  msg('#bookingMessage','Permintaan berhasil dikirim dan berstatus Pending. Mengalihkan ke WhatsApp...');
  const text=`Halo BYSL_MUA, saya sudah mengirim permintaan booking melalui website.\nNama: ${v.customer_name}\nWhatsApp: ${v.whatsapp}\nTanggal: ${v.event_date}\nJam: ${v.event_time}\nLayanan: ${v.service_type}\nAcara: ${v.event_type}\nLokasi: ${v.location}\nCatatan: ${v.notes||'-'}\nMohon info langkah pembayaran DP. Saya memahami booking menunggu persetujuan admin.`;
  const link=wa(text); if(link!=='#')window.open(link,'_blank','noopener'); calendar?.refetchEvents(); setTimeout(()=>modal('#bookingModal',false),1300);
 }catch(err){console.error(err);msg('#bookingMessage',err.message||'Gagal mengirim. Silakan coba lagi.')}finally{button.disabled=false;button.textContent='Kirim permintaan & lanjut WhatsApp'}
});
async function adminCheck(){const {data}=await db.auth.getUser();if(!data.user)return false;const {data:ok,error}=await db.rpc('is_current_user_bysl_admin');return !error&&ok===true}
async function openDashboard(){if(!db){modal('#loginModal');msg('#loginMessage','Konfigurasi Supabase belum diisi.');return}const {data}=await db.auth.getSession();if(!data.session){modal('#loginModal');return}if(!await adminCheck()){msg('#loginMessage','Akun belum terdaftar sebagai admin.');await db.auth.signOut();modal('#loginModal');return}$('#dashboard').classList.add('open');await loadRequests();await loadAdminPortfolio();if(!adminCalendar)adminCalendar=await makeCalendar($('#adminCalendar'),true);else adminCalendar.refetchEvents()}
$('#loginForm').addEventListener('submit',async e=>{e.preventDefault();if(!db)return;const f=new FormData(e.currentTarget);const {error}=await db.auth.signInWithPassword({email:f.get('email'),password:f.get('password')});if(error){msg('#loginMessage',error.message);return}modal('#loginModal',false);await openDashboard()});
$('#logout').addEventListener('click',async()=>{await db.auth.signOut();$('#dashboard').classList.remove('open')});
async function loadRequests(){const el=$('#requestsList');el.textContent='Loading...';const {data,error}=await db.from('bookings').select('*').order('created_at',{ascending:false});if(error){el.textContent=error.message;return}if(!data?.length){el.textContent='Belum ada permintaan booking.';return}el.innerHTML=data.map(b=>`<article class="request"><h4>${esc(b.customer_name)} · ${esc(b.service_type)}</h4><p><b>${esc(b.event_date)} ${esc(b.event_time||'')}</b><br>${esc(b.event_type||'')} · ${esc(b.location||'')}<br>WhatsApp: ${esc(b.whatsapp||'')}<br>Status: <b>${esc(b.status)}</b><br>Catatan: ${esc(b.notes||'-')}</p><div class="request-actions">${b.status==='pending'?`<button class="btn dark" data-act="approve" data-id="${b.id}">Approve (DP verified)</button><button class="btn outline" data-act="reject" data-id="${b.id}">Reject</button>`:''}<button class="btn outline" data-act="delete" data-id="${b.id}">Delete</button></div></article>`).join('');el.querySelectorAll('button').forEach(b=>b.addEventListener('click',()=>bookingAction(b.dataset.id,b.dataset.act)))}
async function bookingAction(id,action){if(action==='delete'&&!confirm('Hapus booking ini?'))return;let result;if(action==='approve')result=await db.rpc('approve_booking',{p_booking_id:id});else if(action==='reject')result=await db.from('bookings').update({status:'rejected'}).eq('id',id);else result=await db.from('bookings').delete().eq('id',id);if(result.error)alert(result.error.message);else if(result.data?.ok===false)alert(result.data.message||'Tidak dapat menyetujui booking.');await loadRequests();calendar?.refetchEvents();adminCalendar?.refetchEvents()}
function adminEvent(ev){const p=ev.extendedProps;if(confirm(`${ev.title} · ${ev.startStr}\n${p.customer_name||''}\nHapus entri ini?`)){db.from('bookings').delete().eq('id',ev.id).then(({error})=>{if(error)alert(error.message);loadRequests();calendar?.refetchEvents();adminCalendar?.refetchEvents()})}}
$('#manualForm').addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.currentTarget);const {error}=await db.from('bookings').insert({customer_name:f.get('customer_name'),event_date:f.get('event_date'),status:f.get('status'),notes:f.get('notes'),service_type:'Admin entry'});if(error)alert(error.message);else{alert('Kalender diperbarui.');e.currentTarget.reset();calendar?.refetchEvents();adminCalendar?.refetchEvents()}});
$('#contentForm').addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.currentTarget),values={brand_name:f.get('brand_name'),regular_price:Number(f.get('regular_price')),daily_capacity:Number(f.get('daily_capacity')),whatsapp_number:f.get('whatsapp_number'),instagram:f.get('instagram'),about_text:f.get('about_text')};for(const [key,value] of Object.entries(values)){const {error}=await db.from('site_settings').upsert({key,value},{onConflict:'key'});if(error){alert(error.message);return}}await loadSettings();calendar?.refetchEvents();alert('Pengaturan berhasil disimpan.')});
async function upload(file,path){const {error}=await db.storage.from(STORAGE_BUCKET).upload(path,file,{upsert:false,contentType:file.type});if(error)throw error;return db.storage.from(STORAGE_BUCKET).getPublicUrl(path).data.publicUrl}
$('#logoForm').addEventListener('submit',async e=>{e.preventDefault();const file=e.currentTarget.logo.files[0];if(!file)return;try{const path=`logo/${Date.now()}-${file.name.replace(/[^\w.-]/g,'_')}`,url=await upload(file,path);const {error}=await db.from('site_settings').upsert({key:'logo_url',value:url},{onConflict:'key'});if(error)throw error;alert('Logo tersimpan. Penggunaan gambar logo pada header akan ditambahkan pada tahap penyesuaian akhir.')}catch(err){alert(err.message)}});
$('#portfolioForm').addEventListener('submit',async e=>{e.preventDefault();const file=e.currentTarget.photo.files[0];if(!file)return;try{const path=`gallery/${Date.now()}-${file.name.replace(/[^\w.-]/g,'_')}`,url=await upload(file,path);const {error}=await db.from('portfolio').insert({image_url:url,storage_path:path,caption:e.currentTarget.caption.value});if(error)throw error;e.currentTarget.reset();await loadPortfolio();await loadAdminPortfolio();alert('Foto portfolio berhasil diunggah.')}catch(err){alert(err.message)}});
async function loadAdminPortfolio(){const {data,error}=await db.from('portfolio').select('*').order('created_at',{ascending:false});if(error)return;$('#adminPortfolio').innerHTML=(data||[]).map(p=>`<div class="admin-portfolio-item"><img src="${esc(p.image_url)}"><button class="btn outline" data-id="${p.id}" data-path="${esc(p.storage_path||'')}">Delete</button></div>`).join('');$('#adminPortfolio').querySelectorAll('button').forEach(b=>b.addEventListener('click',async()=>{if(!confirm('Hapus foto ini?'))return;const {error}=await db.from('portfolio').delete().eq('id',b.dataset.id);if(error){alert(error.message);return}if(b.dataset.path)await db.storage.from(STORAGE_BUCKET).remove([b.dataset.path]);await loadPortfolio();await loadAdminPortfolio()}))}
$('#refresh').addEventListener('click',loadRequests);document.querySelectorAll('.tab').forEach(t=>t.addEventListener('click',()=>{document.querySelectorAll('.tab,.tab-panel').forEach(x=>x.classList.remove('active'));t.classList.add('active');$('#panel-'+t.dataset.tab).classList.add('active');adminCalendar?.updateSize()}));
$('#adminShortcut').addEventListener('click',openDashboard);$('#closeDashboard').addEventListener('click',()=>$('#dashboard').classList.remove('open'));$('#closeBooking').addEventListener('click',()=>modal('#bookingModal',false));$('#closeLogin').addEventListener('click',()=>modal('#loginModal',false));$('#hamb').addEventListener('click',()=>$('#nav').classList.toggle('open'));document.querySelectorAll('#nav a').forEach(a=>a.addEventListener('click',()=>$('#nav').classList.remove('open')));$('#year').textContent=new Date().getFullYear();
if(!configured){console.info('BYSL_MUA: isi config.js untuk mengaktifkan backend Supabase.')}else{await loadSettings();await loadPortfolio();}
calendar=await makeCalendar($('#calendar'));
