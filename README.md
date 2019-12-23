# Gossip Simulator in ELIXIR

1. Implement Gossip and Push-Sum Algorithms for Full, Line, 2D-Rand, 3D-Torus, Honeycomb and Honeycomb-Rand. <br />

2. to\path\project2>mix run main numNodes topology algorithm <br />
	
   numNodes -> number of nodes <br />
   topology -> full, line, rand2D, 3Dtorus, honeycomb and randhoneycomb, algorithm <br />
   algorithm -> gossip, push-sum <br />

3. The algorithms gossip and push-sum works for all the topologies. <br />

   The number of nodes are rounded of as below in the following topologies : <br />

   (i)   HoneyComb - The number of nodes are rounded to the nearest square of an odd number. <br />
   (ii)  HoneyCombRand - The number of nodes are rounded to the nearest square of an odd number plus one, <br />
         a we are generating random pairs of nodes, which needs the total nodes to be even number. <br />
   (iii) 3DTorus - The number of nodes are rounded to the nearest cube. <br />

4. Largest network run with all topologies and algorithm : <br />

   Gossip Algorithm (largest number of nodes) : <br />
   ==========================================

   (i)   Full --------------2900 <br />
   (ii)  Line---------------4000 <br />
   (iii) 2DRand-------------3000 <br />
   (iv)  HoneyComb----------10000 <br />
   (v)   HoneyCombRand------10000 <br />
   (vi)  3DTorus------------8000 <br />
<br />
   Push-sum Algorithm (largest number of nodes) : <br />
   ============================================
<br />
   (i)   Full --------------2900 <br />
   (ii)  Line---------------4000 <br />
   (iii) 2DRand-------------3000 <br />
   (iv)  HoneyComb----------20000 <br />
   (v)   HoneyCombRand------20000 <br />
   (vi)  3DTorus------------15000 <br />
<br />
5. "remove_nodes" is the variable used for failure model implementation, nodes to be failed can be mentioned here. <br />
   Default number is 10. <br />


