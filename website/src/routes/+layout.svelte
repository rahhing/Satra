<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();

	const siteSchema = {
		"@context": "https://schema.org",
		"@type": "WebSite",
		"name": "Satra",
		"url": "https://plezy.app"
	};

	const orgSchema = {
		"@context": "https://schema.org",
		"@type": "Organization",
		"name": "Satra",
		"url": "https://plezy.app",
		"logo": "https://plezy.app/og/satra-social.png",
		"sameAs": ["https://github.com/rahhing/Satra"]
	};
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	{@html `<script type="application/ld+json">${JSON.stringify(siteSchema)}</script>`}
	{@html `<script type="application/ld+json">${JSON.stringify(orgSchema)}</script>`}
</svelte:head>
{@render children()}
