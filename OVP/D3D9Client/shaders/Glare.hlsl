// ===================================================
// Copyright (C) 2022 Jarmo Nikkanen
// licensed under MIT
// ===================================================



// ====================================================================
// GPU based computation of local lights visibility (including the Sun)
// ====================================================================

float ilerp(float a, float b, float x)
{
	return saturate((x - a) / (b - a));
}

float3 HDRtoLDR(float3 hdr)
{
	float3 h2 = hdr * hdr;
	return hdr * pow(max(0, 1.0f + h2 * h2), -0.25);
}

sampler2D tDepth;

#define LocalKernelSize 57
static const float iLKS = 1.0f / LocalKernelSize;

uniform extern struct {
	float4x4 mVP;
	float4x4 mSVP;
	float4 vSrc;
	float3 vDir;
} cbPS;

uniform extern float2 cbKernel[LocalKernelSize];

struct LData
{
	float4 posH : POSITION0;	// For rendering
	float4 smpH : TEXCOORD0;	// For sampling screen depth bufer
	float3 posW : TEXCOORD1;	// Camera centric location ECL 
	float  cone : TEXCOORD3;	// Attennuation by light-cone
};

LData VisibilityVS(float posL : POSITION0, float4 posW : TEXCOORD0)
{
	LData outVS = (LData)0;
	outVS.posH = mul(float4(posL.x + 0.5f, 0.0f, 0.0f, 1.0f), cbPS.mVP); // Render projection
	outVS.smpH = mul(float4(posW.xyz, 1.0f), cbPS.mSVP); // Depth sampling projection 
	outVS.posW = posW.xyz;
	outVS.cone = posW.a;
	return outVS;
}

float4 VisibilityPS(LData frg) : COLOR
{
	float4 smpH = frg.smpH;
	smpH.xyz /= smpH.w;
	float2 sp = smpH.xy * float2(0.5f, -0.5f) + float2(0.5f, 0.5f); // Scale and offset to 0-1 range

	if (sp.x < 0 || sp.y < 0) return 0.0f;				// If a sample is outside border -> obscured
	if (sp.x > 1 || sp.y > 1) return 0.0f;

	float2 vScale = 40.0f * cbPS.vSrc.zz;				// Kernel scale factor (from unit kernel)
	float fDepth = dot(frg.posW, cbPS.vDir) - 0.25f;	// Depth to compare
	float fRet = 0;

	[unroll] for (int i = 0; i < LocalKernelSize; i++) {
		float2 s = sp + cbKernel[i].xy * vScale;
		if (s.x < 0 || s.x > 1) { fRet += iLKS;	continue; }
		if (s.y < 0 || s.y > 1) { fRet += iLKS;	continue; }
		float d = tex2D(tDepth, s).a;
		fRet += d > 0.1f && d < fDepth ? iLKS : 0;
	}

	return 1.0f - fRet;
}



// ====================================================================
// Rendering of glares for the Sun and local lights
// ====================================================================

sampler2D tVis;	// Pre-computed visibility factors
sampler2D tTex;

uniform extern struct {
	float4x4	mVP;
	float4		Pos;
	float4		Color;
	float		GPUId;
	float		Intensity;
} Const;


struct OutputVS
{
	float4 posH : POSITION0;
	float3 uvi  : TEXCOORD0;
};


OutputVS GlareVS(float3 posL : POSITION0, float2 tex0 : TEXCOORD0)
{
	// Zero output.
	OutputVS outVS = (OutputVS)0;

	float v_factor = tex2Dlod(tVis, float4(Const.GPUId, 0.5f, 0, 0)).r;
	float s = smoothstep(0.4f, 1.0f, v_factor);
	posL.xy *= Const.Pos.zw * (0.05f + s * 2.5f) * sqrt(Const.Intensity);
	posL.xy += Const.Pos.xy;

	outVS.posH = mul(float4(posL.xy - 0.5f, 0.0f, 1.0f), Const.mVP);
	outVS.uvi = float3(tex0.xy, s);

	return outVS;
}


float4 GlarePS(OutputVS frg) : COLOR
{
	if (frg.uvi.z < 0.02f) discard;
	float3 c = saturate(Const.Color.rgb); 
	
	float t = tex2D(tTex, frg.uvi.xy).r;  // Texture intensity
	float a = t * frg.uvi.z * sqrt(Const.Intensity);
	
	return float4(HDRtoLDR(c * t), saturate(1.0f - exp(-a * 0.5f)));
}

/*
float4 GlarePS(OutputVS frg) : COLOR
{
	if (frg.uvi.z < 0.02f) discard;
	float3 c = saturate(Const.Color.rgb / max(Const.Color.r, 0.0001f)); // Normalize color
	c *= c; // Amplify color cast, HDR equations flatten it

	float t = tex2D(tTex, frg.uvi.xy).r;  // Texture intensity
	float a = t * frg.uvi.z * sqrt(Const.Intensity);

	return float4(HDRtoLDR(c * t), saturate(1.0f - exp(-a)));
}
*/





// ======================================================================
// Render sun texture "Glare"
//
float4 CreateSunGlarePS(float u : TEXCOORD0, float v : TEXCOORD1) : COLOR
{
	u = u * 2.0 - 1.0;	v = v * 2.0 - 1.0;

	float a = atan2(u, v);
	float r = sqrt(u * u + v * v);

	float q = 0.5f + 0.3f * pow(sin(3.0f * a), 4.0f);
	float w = 0.5f + 0.2f * pow(sin(30.0f * a), 2.0f) * pow(sin(41.0f * a), 2.0f);

	//float I = pow(max(0, 2.0f * (1 - r / q)), 12.0f);
	//float K = pow(max(0, 2.0f * (1 - r / w)), 12.0f);
	//float I = exp(max(0, 10.0f * (1 - r / q))) - 1.0f;
	//float K = exp(max(0, 10.0f * (1 - r / w))) - 1.0f;

	float I = pow(max(0, (1 - r / q)), 6.0f) * 2.0f;
	float K = pow(max(0, (1 - r / w)), 6.0f) * 3.0f;
	float L = ilerp(0.04, 0.02, r) * 16.0f;
	float S = ilerp(1.7f, 0.35f, r);
	L *= L;
	L += S * S * 0.40f;

	return float4(max(I + L,K + L), 0, 0, 1);
}



// ======================================================================
// Render Sun texture
//
float4 CreateSunTexPS(float u : TEXCOORD0, float v : TEXCOORD1) : COLOR
{
	u = u * 2.0 - 1.0;	v = v * 2.0 - 1.0;

	float a = atan2(u, v);
	float r = sqrt(u * u + v * v);

	float q = 0.5f + 1.0f * pow(sin(3.0f * a), 4.0f);
	float w = 0.5f + 0.8f * pow(sin(30.0f * a), 2.0f) * pow(sin(41.0f * a), 2.0f);

	float I = pow(max(0, (1 - r / q)), 6.0f) * 2;
	float K = pow(max(0, (1 - r / w)), 6.0f) * 6;

	float L = ilerp(0.15, 0.10, r) * 4.0f;
	float T = max(0, max(I + L, K + L));

	T = saturate(1.0f - exp(-T));
	return float4(1, 1, 1, T);
}


// ======================================================================
// Render "Glare" for local light sources
//
float4 CreateLocalGlarePS(float u : TEXCOORD0, float v : TEXCOORD1) : COLOR
{
	u = u * 2.0 - 1.0;	v = v * 2.0 - 1.0;

	float a = atan2(u, v);
	float r = sqrt(u * u + v * v);

	float q = 0.5f + 0.5f * pow(sin(3.0f * a), 4.0f);
	float w = 0.5f + 0.3f * pow(sin(30.0f * a), 2.0f) * pow(sin(41.0f * a), 2.0f);

	float I = pow(max(0, (1 - r / q)), 6.0f) * 4.0f;
	float K = pow(max(0, (1 - r / w)), 6.0f) * 8.0f;

	float L = ilerp(0.15, 0.10, r) * 4.0f;

	return float4(max(I + L,K + L), 0, 0, 1);
}


