<?php

# Mute branding. Tracked in git; mounted into the wikibase container by
# docker-compose.override.local.yml and loaded from /config/LocalSettings.php
# (see README, "Branding"). The logo file is mounted at the path below.

$wgSitename = 'Corpus Mute';

$wgLogos = [
	'1x' => "$wgScriptPath/resources/assets/corpus-mute-logo.jpg",
	'icon' => "$wgScriptPath/resources/assets/corpus-mute-logo.jpg",
];

# Skin: Minerva (already loaded by the WBS defaults). MobileFrontend serves the
# mobile variety to mobile devices and adds the "Mobile view" / "Desktop" switcher
# to the footer; the desktop view also uses Minerva.
# MobileFrontend lives in wikibase-suite/config/extensions/MobileFrontend (branch
# REL1_46, matching MediaWiki 1.46; gitignored, mounted at extensions/extensions/).
$wgDefaultSkin = 'minerva';

wfLoadExtension( 'extensions/MobileFrontend' );
$wgMFAutodetectMobileView = true;      # mobile browsers get the mobile view automatically
$wgMFDefaultSkinClass = 'SkinMinerva'; # skin used in the mobile view

# Left (hamburger) menu in Minerva: add a "Query" link to the SPARQL Query UI (/query/).
# Minerva builds that menu in PHP with no hook for extra entries (only Home and Random can be
# overridden via MediaWiki:Sidebar), so the <li> is appended client-side, copying the markup of
# the Random entry. The icon is a Codex "search" icon applied as a CSS mask, because Minerva only
# ships the icons it uses itself.
$wgHooks['BeforePageDisplay'][] = static function ( $out, $skin ): void {
	if ( $skin->getSkinName() !== 'minerva' ) {
		return;
	}
	$out->addInlineStyle(
		'.minerva-icon--query{' .
		'-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 20 20\'%3E' .
		'%3Cpath d=\'M12.2 13.6a7 7 0 1 1 1.4-1.4l5.4 5.4-1.4 1.4zM3 8a5 5 0 1 0 10 0A5 5 0 0 0 3 8\'/%3E%3C/svg%3E") center/contain no-repeat;' .
		'mask:url("data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 20 20\'%3E' .
		'%3Cpath d=\'M12.2 13.6a7 7 0 1 1 1.4-1.4l5.4 5.4-1.4 1.4zM3 8a5 5 0 1 0 10 0A5 5 0 0 0 3 8\'/%3E%3C/svg%3E") center/contain no-repeat;' .
		'background-color:#36393e;background-image:none}' .
		'.page-Main_Page .firstHeading,.page-Main_Page #toc{display:none!important}'
	);
	$out->addInlineScript(
		'(function f(){if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",f);return;}' .
		'var l=document.querySelector("#p-navigation");if(!l||l.querySelector(".menu__item--query")){return;}' .
		'var r=l.querySelector(".menu__item--random"),li=r?r.closest("li"):null;' .
		'var n=li?li.cloneNode(true):document.createElement("li");' .
		'var a=n.querySelector("a");' .
		'a.className=a.className.replace("menu__item--random","menu__item--query");' .
		'a.href="/query/";' .
		'var i=a.querySelector(".minerva-icon");i.className="minerva-icon minerva-icon--query";' .
		'a.querySelector(".toggle-list-item__label").textContent="Query";' .
		'l.appendChild(n);})();'
	);
};

# "In more languages" box on item/property pages: show German, then Spanish after the
# interface language (English). Without this, Wikibase asks the language selector (ULS)
# for "frequent" languages, which for most visitors means English variants such as
# en-us. Listing the languages as "user specified" also switches that ULS suggestion off.
# Users with their own Babel languages keep those, with de/es appended if missing.
# (Done in BeforePageDisplay via addJsConfigVars: those vars are merged after
# Wikibase's own MakeGlobalVariablesScript handler, which would overwrite ours.)
$wgHooks['BeforePageDisplay'][] = static function ( $out ): void {
	$title = $out->getTitle();
	if ( !$title || !in_array( $title->getContentModel(), [ 'wikibase-item', 'wikibase-property' ], true ) ) {
		return; # not an item/property page
	}
	$extra = [ 'de', 'es' ];
	$babel = new \Wikibase\Repo\BabelUserLanguageLookup();
	$user = $out->getUser();
	$ui = $out->getLanguage()->getCode();
	$out->addJsConfigVars( [
		'wbUserPreferredContentLanguages' => array_values( array_unique( array_merge(
			[ $ui ], $babel->getAllUserLanguages( $user ), $extra ) ) ),
		'wbUserSpecifiedLanguages' => array_values( array_unique( array_merge(
			$babel->getUserSpecifiedLanguages( $user ), $extra ) ) ),
	] );
	# Hide language rows that have no label/description (e.g. German, Spanish, "default for all languages")
	# so the "No label defined" / "No description defined" warnings don't appear.
	# Desktop view: hide all non-English rows in the "In more languages" table.
	# Mobile view: hide the entire "In more languages" section (it only shows missing languages).
	$out->addInlineStyle(
		'.wikibase-entitytermsforlanguageview-mul{display:none!important}' .
		'.wikibase-entitytermsforlanguageview{display:none!important}' .
		'.wikibase-entitytermsforlanguageview-en{display:table-row!important}' .
		'.wb-ui-in-more-languages-expandable{display:none!important}'
	);
};
