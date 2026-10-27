const script = `<script type="text/javascript">
  (function(m,e,t,r,i,k,a){
    m[i]=m[i]||function(){(m[i].a=m[i].a||[]).push(arguments)};
    m[i].l=1*new Date();
    for (var j = 0; j < document.scripts.length; j++) {if (document.scripts[j].src === r) { return; }}
    k=e.createElement(t),a=e.getElementsByTagName(t)[0],k.async=1,k.src=r,a.parentNode.insertBefore(k,a)
  })(window, document,'script','https://mc.yandex.ru/metrika/tag.js?id=113828609', 'ym');

  ym(113828609, 'init', {ssr:true, webvisor:true, clickmap:true, ecommerce:"dataLayer", referrer: document.referrer, url: location.href, accurateTrackBounce:true, trackLinks:true});
</script>`;

const fallback = '<noscript><div><img src="https://mc.yandex.ru/watch/113828609" style="position:absolute; left:-9999px;" alt="" /></div></noscript>';

export function renderAnalytics({ isRoot = false } = {}) {
  // Neutral routes redirect in JavaScript; only their no-JavaScript fallback is a page view.
  return `<!-- Yandex.Metrika counter -->\n${isRoot ? '' : `${script}\n`}${fallback}\n<!-- /Yandex.Metrika counter -->`;
}
